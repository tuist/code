defmodule Code.HTTP.GitBackend do
  @moduledoc """
  Streams a request through `git` and its output back to the client.

  Both directions have to be live. A `git clone` of a large monorepo produces
  gigabytes that must not be buffered, and a `git push` sends a packfile of
  arbitrary size that must not be buffered either. So the request body is fed
  to the process in chunks, and its output is drained in the same loop.

  Draining while writing is not an optimisation. A pipe has a fixed buffer: if
  we wrote the whole request without reading, and the process wrote enough
  output to fill its side, both ends would block forever waiting for the other.
  Interleaving is what makes that impossible.

  ## Why the response starts only after the request is consumed

  Output produced while the request is still arriving is held in memory, and
  the response is not begun until the request body is fully written. That looks
  like needless buffering and is not:

  Git speaks HTTP through libcurl, which sends `Expect: 100-continue` for
  bodies over a kilobyte and waits to be told to proceed. The `100 Continue` is
  emitted when the server first reads the body — so a server that sends its
  response headers *before* reading has already answered, and a client that is
  still waiting for permission to send can stall until something times it out.
  It is the kind of bug that hides on loopback, where curl's short wait expires
  and it sends anyway, and appears the moment a proxy sits in the path.

  In normal traffic the two directions are never large at once — `upload-pack`
  receives a tiny request and produces a huge response, `receive-pack` the
  reverse — so only the small side is ever held. That is a property of
  well-behaved clients, though, not of the protocol: a client can send a
  request that makes `upload-pack` produce gigabytes and then simply keep its
  request body open, and the buffer would grow for as long as it cared to wait.

  So the buffer is capped. Past `@max_buffered` bytes the response is started
  and output streams from then on, which is safe precisely because a client
  that has already made the server produce that much output has plainly stopped
  waiting for `100 Continue`. The rest of the request body is still read and
  fed to the process after that point, interleaved with forwarding its
  output, so a request whose body outlives the cap is served in full rather
  than cut off where the buffer filled.

  A client that disconnects mid-clone, or a handler that crashes, takes the
  `git` process with it via `Code.Git.terminate/1`. Leaked `upload-pack`
  processes are the classic way a Git server degrades into unexplained load.
  """

  require Logger

  import Plug.Conn

  alias Code.Git

  @read_chunk 64 * 1024
  @idle_timeout :timer.minutes(30)

  # How much output may be held before the response is started regardless. A
  # well-behaved request never comes close; a hostile one is capped here rather
  # than by the node's memory.
  @max_buffered 4 * 1024 * 1024

  @doc """
  Run `git <args>` against `repo_path`, streaming `conn`'s body in and the
  process output back as the response.
  """
  @spec run(Plug.Conn.t(), Path.t(), [String.t()], keyword()) :: Plug.Conn.t()
  def run(conn, repo_path, args, opts \\ []) do
    service = Keyword.get(opts, :service)

    case request_encoding(conn, service) do
      {:ok, :identity} ->
        run_stream(conn, repo_path, args, opts)

      {:ok, :gzip} ->
        decoder = :zlib.open()
        counter = :counters.new(1, [])

        try do
          :ok = :zlib.inflateInit(decoder, 31, :error)

          conn
          |> put_private(:git_request_decoder, {decoder, counter})
          |> run_stream(repo_path, args, opts)
        after
          :telemetry.execute([:code, :git, :request_decoded], %{bytes: :counters.get(counter, 1)}, %{
            service: service
          })

          :zlib.close(decoder)
        end

      {:error, :unsupported_encoding} ->
        reject_encoding(opts, :unsupported_encoding)
        send_resp(conn, 415, "code: unsupported request content encoding\n")
    end
  end

  @doc "Validate request encoding before materializing a repository."
  def request_encoding(conn, service) do
    case Enum.map(get_req_header(conn, "content-encoding"), &(String.trim(&1) |> String.downcase())) do
      encoding when encoding in [[], ["identity"]] -> {:ok, :identity}
      [encoding] when encoding in ["gzip", "x-gzip"] and service == "git-upload-pack" -> {:ok, :gzip}
      _ -> {:error, :unsupported_encoding}
    end
  end

  @doc false
  def reject_encoding(opts, reason) do
    metadata = %{service: Keyword.get(opts, :service), repo_id: Keyword.get(opts, :repo_id), reason: reason}
    :telemetry.execute([:code, :git, :encoding_rejected], %{count: 1}, metadata)
    Logger.warning("Git request encoding rejected", Map.to_list(metadata))
  end

  defp run_stream(conn, repo_path, args, opts) do
    content_type = Keyword.fetch!(opts, :content_type)
    env = Keyword.get(opts, :env, [])
    started = System.monotonic_time(:millisecond)

    port = Git.stream(repo_path, args, env: env)

    result =
      case pump_request(conn, port, {[], 0}) do
        {status, conn, {buffered, _bytes}} when status in [:done, :full] ->
          buffered = Enum.reverse(buffered)

          conn =
            conn
            |> put_resp_content_type(content_type)
            |> put_no_cache()
            |> send_chunked(200)

          with {:ok, conn, bytes} <- flush_buffered(conn, buffered),
               {:ok, conn, bytes} <-
                 if(status == :full, do: stream_request(conn, port, bytes), else: {:ok, conn, bytes}) do
            drain(conn, port, bytes)
          end

        {:error, conn, reason} ->
          # Nothing has been sent yet, so this can still be an honest status
          # code rather than a truncated stream.
          {:aborted, refuse(conn, reason), reason}
      end

    finish(result, port, started, opts)
  end

  defp refuse(conn, :too_large), do: send_resp(conn, 413, "code: decoded request is too large\n")

  defp refuse(conn, _reason) do
    send_resp(conn, 400, "code: the request could not be read\n")
  end

  defp flush_buffered(conn, buffered) do
    Enum.reduce_while(buffered, {:ok, conn, 0}, fn data, {:ok, conn, bytes} ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, {:ok, conn, bytes + byte_size(data)}}
        {:error, reason} -> {:halt, {:error, conn, {:client_gone, reason}}}
      end
    end)
  end

  defp finish({:aborted, conn, reason}, port, started, opts) do
    Git.terminate(port)
    if reason in [:invalid_encoding, :too_large], do: reject_encoding(opts, reason)

    :telemetry.execute(
      [:code, :git, :aborted],
      %{duration_ms: System.monotonic_time(:millisecond) - started},
      %{service: Keyword.get(opts, :service), repo_id: Keyword.get(opts, :repo_id), reason: reason}
    )

    conn
  end

  defp finish({:ok, conn, bytes}, _port, started, opts) do
    :telemetry.execute(
      [:code, :git, :served],
      %{duration_ms: System.monotonic_time(:millisecond) - started, bytes: bytes},
      %{service: Keyword.get(opts, :service), repo_id: Keyword.get(opts, :repo_id)}
    )

    conn
  end

  defp finish({:error, conn, reason}, port, started, opts) do
    close(port)
    if reason in [:invalid_encoding, :too_large], do: reject_encoding(opts, reason)

    :telemetry.execute(
      [:code, :git, :aborted],
      %{duration_ms: System.monotonic_time(:millisecond) - started},
      %{service: Keyword.get(opts, :service), repo_id: Keyword.get(opts, :repo_id), reason: reason}
    )

    conn
  end

  # Read the request body in chunks, writing each to the process and collecting
  # whatever it has produced so far. Reading the body is also what makes the
  # server emit `100 Continue`, which is why it happens before any response.
  #
  # Returns `:done` once the body is consumed, or `:full` when the output cap
  # was reached first, in which case the caller starts the response and
  # carries on with `stream_request/3`.
  defp pump_request(conn, port, acc) do
    case read_body(conn, length: @read_chunk, read_length: @read_chunk) do
      {:more, chunk, conn} ->
        case feed(conn, port, chunk) do
          :ok ->
            case collect_available(port, acc) do
              {:cont, acc} -> pump_request(conn, port, acc)
              {:full, acc} -> {:full, conn, acc}
            end

          reason when reason in [:invalid_encoding, :too_large] ->
            {:error, conn, reason}

          :closed ->
            # The process has exited; what it wrote is in the mailbox and its
            # exit status follows it. The rest of the body has no reader.
            {:done, conn, acc}
        end

      {:ok, chunk, conn} ->
        finish_request(conn, port, chunk, acc)

      {:error, reason} ->
        {:error, conn, {:request_body, reason}}
    end
  end

  defp finish_request(conn, port, chunk, acc) do
    # Stateless requests carry their own flush packet; the process can finish
    # without the EOF that an Erlang port cannot signal.
    case finish_feed(conn, port, chunk) do
      reason when reason in [:invalid_encoding, :too_large] ->
        {:error, conn, reason}

      _ ->
        {_state, acc} = collect_available(port, acc)
        {:done, conn, acc}
    end
  end

  # The response has started because the output cap was reached, but the
  # client is still sending. Keep feeding the body to the process — abandoning
  # it would leave `git` waiting for input that never comes, and the client
  # waiting for a response that never ends — while forwarding output as it
  # appears so neither side accumulates.
  #
  # Both directions have backpressure: `Port.command/2` suspends this process
  # while the port's queue is busy, and `chunk/2` blocks on the client socket.
  # Neither can grow without bound, which is the property the output cap
  # exists to preserve.
  defp stream_request(conn, port, bytes) do
    case read_body(conn, length: @read_chunk, read_length: @read_chunk) do
      {:more, chunk, conn} ->
        with :ok <- feed(conn, port, chunk),
             {:ok, conn, bytes} <- forward_available(conn, port, bytes) do
          stream_request(conn, port, bytes)
        else
          :closed -> {:ok, conn, bytes}
          reason when reason in [:invalid_encoding, :too_large] -> {:error, conn, reason}
          {:error, conn, reason} -> {:error, conn, reason}
        end

      {:ok, chunk, conn} ->
        case finish_feed(conn, port, chunk) do
          reason when reason in [:invalid_encoding, :too_large] -> {:error, conn, reason}
          _ -> {:ok, conn, bytes}
        end

      {:error, reason} ->
        {:error, conn, {:request_body, reason}}
    end
  end

  # Only data is taken here. An exit status stays in the mailbox for `drain/3`,
  # which has to see it after every byte that preceded it.
  defp forward_available(conn, port, bytes) do
    receive do
      {^port, {:data, data}} ->
        case chunk(conn, data) do
          {:ok, conn} -> forward_available(conn, port, bytes + byte_size(data))
          {:error, reason} -> {:error, conn, {:client_gone, reason}}
        end
    after
      0 -> {:ok, conn, bytes}
    end
  end

  # Writing to a port whose process has exited raises; that is not an error
  # here, only the end of anyone listening.
  defp finish_feed(conn, port, chunk) do
    with :ok <- feed(conn, port, chunk) do
      case conn.private[:git_request_decoder] do
        nil -> :ok
        {decoder, _counter} -> :zlib.inflateEnd(decoder)
      end
    end
  rescue
    ErlangError -> :invalid_encoding
  end

  defp feed(_conn, _port, ""), do: :ok

  defp feed(conn, port, chunk) do
    case conn.private[:git_request_decoder] do
      nil -> write(port, chunk)
      decoder -> inflate(port, decoder, chunk)
    end
  end

  # safeInflate bounds each output buffer even when a small wire chunk expands
  # enormously. Feed each buffer directly rather than assembling the body.
  defp inflate(port, decoder, chunk) do
    inflate_loop(port, decoder, chunk)
  rescue
    ErlangError -> :invalid_encoding
  end

  defp inflate_loop(port, {decoder, counter} = state, chunk) do
    {status, output} = :zlib.safeInflate(decoder, chunk)
    :counters.add(counter, 1, IO.iodata_length(output))

    if :counters.get(counter, 1) > Code.Config.git_max_decoded_request_bytes() do
      :too_large
    else
      with :ok <- write(port, output) do
        if status == :continue, do: inflate_loop(port, state, <<>>), else: :ok
      end
    end
  end

  defp write(port, chunk) do
    Port.command(port, chunk)
    :ok
  rescue
    ArgumentError -> :closed
  end

  # Non-blocking: take whatever the process has already written so its pipe
  # cannot fill while we are still feeding it. Stops accumulating once the cap
  # is reached, so the caller starts the response and streams the rest.
  defp collect_available(port, {buffered, bytes} = acc) do
    if bytes >= @max_buffered do
      {:full, acc}
    else
      receive do
        {^port, {:data, data}} -> collect_available(port, {[data | buffered], bytes + byte_size(data)})
      after
        0 -> {:cont, acc}
      end
    end
  end

  defp drain(conn, port, bytes) do
    receive do
      {^port, {:data, data}} ->
        case chunk(conn, data) do
          {:ok, conn} -> drain(conn, port, bytes + byte_size(data))
          {:error, reason} -> {:error, conn, {:client_gone, reason}}
        end

      {^port, {:exit_status, 0}} ->
        {:ok, conn, bytes}

      {^port, {:exit_status, status}} ->
        # The response is already in flight, so the status cannot become an
        # HTTP error. Git will have written its own protocol-level error to
        # the client before exiting.
        Logger.warning("Git process exited mid-stream", status: status, bytes: bytes)
        {:ok, conn, bytes}
    after
      @idle_timeout -> {:error, conn, :timeout}
    end
  end

  defp close(port), do: Git.terminate(port)

  @doc """
  The advertisement served from `info/refs`.

  Git decides whether a server is smart or dumb from this exact framing, so the
  service header is generated here and the reference list comes from `git`.
  """
  @spec advertise(Plug.Conn.t(), Path.t(), String.t(), keyword()) :: Plug.Conn.t()
  def advertise(conn, repo_path, service, opts \\ []) do
    env = Keyword.get(opts, :env, [])
    repo_id = Keyword.get(opts, :repo_id)
    command = String.replace_prefix(service, "git-", "")

    # Standard error is kept out of the body: the body is pkt-line framed
    # protocol data, and a single warning line interleaved into it corrupts
    # the framing for the client. It is logged instead.
    case Git.run(repo_path, [command, "--stateless-rpc", "--advertise-refs", repo_path],
           env: env,
           stderr: :separate
         ) do
      {:ok, advertisement} ->
        body =
          if protocol_v2?(env) do
            # Protocol v2 advertises capabilities rather than refs, and the
            # service header is still expected over HTTP.
            Code.Git.PktLine.service_header(service) <> advertisement
          else
            Code.Git.PktLine.service_header(service) <> advertisement
          end

        conn
        |> put_resp_content_type("application/x-#{service}-advertisement")
        |> put_no_cache()
        |> send_resp(200, body)

      {:error, reason} ->
        Logger.warning("Git advertisement failed", repo_id: repo_id, service: service, reason: reason)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(500, "code: could not read the repository\n")
    end
  end

  defp protocol_v2?(env), do: Enum.any?(env, fn {k, v} -> k == "GIT_PROTOCOL" and v =~ "version=2" end)

  @doc """
  Headers that stop any cache from serving a stale advertisement.

  Git's own documentation requires these; without them an intermediate proxy
  can hand a client a reference list from before a push and produce failures
  that look like corruption.
  """
  @spec put_no_cache(Plug.Conn.t()) :: Plug.Conn.t()
  def put_no_cache(conn) do
    conn
    |> put_resp_header("expires", "Fri, 01 Jan 1980 00:00:00 GMT")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("cache-control", "no-cache, max-age=0, must-revalidate")
  end
end
