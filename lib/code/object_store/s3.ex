defmodule Code.ObjectStore.S3 do
  @moduledoc """
  S3-compatible object store.

  Requests are signed with SigV4 and issued through `Req`, which keeps full
  control over the conditional headers the write-ahead log depends on:

    * `If-None-Match: *` on the very first write of a repository's WAL index,
      so two nodes racing to create the same repository cannot both win.
    * `If-Match: <etag>` on every subsequent index update, which is the
      compare-and-swap that linearizes pushes.
    * `If-None-Match: <etag>` on reads, so an up-to-date replica pays for a
      metadata round trip instead of a body transfer.

  Packfiles are content-addressed and written with `If-None-Match: *`; a
  precondition failure there means the exact same bytes are already stored,
  which is success, not an error.

  Works against AWS S3, MinIO, Tigris, Cloudflare R2 and Ceph. Set
  `path_style: true` (the default) for anything that is not AWS proper.
  """

  @behaviour Code.ObjectStore

  # Sub-chunk each streamed upload reads at a time. Large enough that the
  # per-chunk overhead is irrelevant, small enough that memory stays flat
  # regardless of the file.
  @chunk 1024 * 1024

  # S3 refuses a single PUT above five gibibytes. Above that we switch to
  # multipart, whose own ceiling is `part_size * 10_000` (S3's part-count
  # limit).
  @single_put_max 5 * 1024 * 1024 * 1024
  @multipart_max_parts 10_000
  @default_multipart_threshold 100 * 1024 * 1024
  @default_multipart_part_size 64 * 1024 * 1024
  # S3 refuses a non-final part below 5 MiB and any part above 5 GiB, but only
  # at completion time, after every byte has been sent.
  @min_part_size 5 * 1024 * 1024
  @max_part_size 5 * 1024 * 1024 * 1024

  require Logger

  @doc """
  Whether `size` is a part size S3 accepts for a multipart upload.

  Checked at boot for `CODE_S3_MULTIPART_PART_SIZE_BYTES` and again before
  any upload, so a bad value fails before a byte is transferred.
  """
  @spec valid_part_size?(term()) :: boolean()
  def valid_part_size?(size), do: is_integer(size) and size >= @min_part_size and size <= @max_part_size

  @doc """
  The largest object a single unsegmented `PUT` can carry.

  Files above this size are uploaded through S3 multipart from `put_file/4`,
  which raises the effective ceiling to `part_size * 10_000` — a few hundred
  gibibytes at the default part size.
  """
  @spec single_put_max_size() :: pos_integer()
  def single_put_max_size, do: @single_put_max

  @doc """
  The multipart-upload ceiling implied by the current part size.

  S3 caps a multipart upload at 10,000 parts, so the largest object this
  backend can store is that limit times the part size. Nothing calls this at
  runtime; it exists so an operator can see the number by hand.
  """
  @spec max_object_size(keyword()) :: pos_integer()
  def max_object_size(config \\ []), do: multipart_part_size(config) * @multipart_max_parts

  defp multipart_threshold(config),
    do: Keyword.get(config, :multipart_threshold, @default_multipart_threshold)

  defp multipart_part_size(config),
    do: Keyword.get(config, :multipart_part_size, @default_multipart_part_size)

  @impl true
  def get(key, opts, config) do
    headers =
      case Keyword.get(opts, :etag) do
        nil -> []
        etag -> [{"if-none-match", etag}]
      end

    case request(:get, key, config, headers: headers, decode_body: false) do
      {:ok, %{status: 200} = resp} -> {:ok, resp.body, etag(resp)}
      {:ok, %{status: 304}} -> {:ok, :not_modified}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, resp} -> {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put(key, body, opts, config) do
    headers =
      []
      |> maybe_header("if-match", Keyword.get(opts, :if_match))
      |> maybe_header("if-none-match", Keyword.get(opts, :if_none_match))
      |> maybe_header("content-type", Keyword.get(opts, :content_type, "application/octet-stream"))

    case request(:put, key, config, headers: headers, body: IO.iodata_to_binary(body), decode_body: false) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, etag(resp)}

      # 412 is a lost compare-and-swap. 409 is what some implementations return
      # when two conditional writes collide; both mean "retry against the
      # current state", never "the write partially applied".
      {:ok, %{status: status}} when status in [409, 412] ->
        {:error, :precondition_failed}

      {:ok, resp} ->
        {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def put_file(key, source, opts, config) do
    case File.stat(source) do
      {:ok, %{size: size}} ->
        part_size = multipart_part_size(config)
        multipart_ceiling = part_size * @multipart_max_parts
        # An operator who raises the threshold above the single-PUT limit
        # would otherwise route a 6 GiB file through single-PUT and hit
        # `EntityTooLarge`. Clamp so that never happens by accident.
        effective_threshold = min(multipart_threshold(config), @single_put_max)

        cond do
          size > effective_threshold and not valid_part_size?(part_size) ->
            {:error, {:invalid_multipart_part_size, part_size, @min_part_size, @max_part_size}}

          size > multipart_ceiling ->
            # Naming the effective limit means an operator reading the log
            # learns what to do about it rather than seeing an opaque
            # `EntityTooLarge` from S3.
            {:error, {:object_too_large, key, size, multipart_ceiling}}

          size > effective_threshold ->
            key
            |> multipart_put_file(source, size, part_size, opts, config)
            |> resolve_conflict(key, opts, config)

          true ->
            key |> single_put_file(source, size, opts, config) |> resolve_conflict(key, opts, config)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp single_put_file(key, source, size, opts, config) do
    headers =
      [{"content-length", Integer.to_string(size)}]
      |> maybe_header("if-match", Keyword.get(opts, :if_match))
      |> maybe_header("if-none-match", Keyword.get(opts, :if_none_match))
      |> maybe_header("content-type", Keyword.get(opts, :content_type, "application/octet-stream"))

    # An enumerable body makes Req sign with UNSIGNED-PAYLOAD, which is why
    # content-length has to be explicit. The payload is therefore not
    # covered by the signature, so the transport has to be — use HTTPS for
    # anything but a local store.
    options = [
      headers: headers,
      body: File.stream!(source, @chunk),
      decode_body: false,
      # Not retried: the body is a stream and cannot be replayed, and a
      # half-sent object is worse than a reported failure the caller
      # retries from the start.
      retry: false
    ]

    case request(:put, key, config, options) do
      {:ok, %{status: status} = resp} when status in 200..299 -> {:ok, etag(resp)}
      {:ok, %{status: 412}} -> {:error, :precondition_failed}
      {:ok, %{status: 409}} -> {:error, :conflict}
      {:ok, resp} -> {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A 409 on a file upload is `ConditionalRequestConflict`: a concurrent write
  # or delete of the same key, which says nothing about whether the object now
  # exists. Callers treat `:precondition_failed` on a create-only write as
  # "already stored" (`Code.WAL` does, for packs), so report that only when the
  # object is really there; otherwise it is a conflict the caller must retry.
  defp resolve_conflict({:error, :conflict}, key, opts, config) do
    if Keyword.get(opts, :if_none_match) == "*" and object_present?(key, config) do
      {:error, :precondition_failed}
    else
      {:error, {:conflict, 409}}
    end
  end

  defp resolve_conflict(result, _key, _opts, _config), do: result

  defp object_present?(key, config) do
    match?({:ok, %{status: 200}}, request(:head, key, config, decode_body: false))
  end

  # Multipart upload. Create-only is enforced where it can be atomic: on
  # `CompleteMultipartUpload`, with `If-None-Match: *`. The HEAD before
  # initiate only saves re-sending bytes that are already stored; it arbitrates
  # nothing. Only `"*"` is supported: `if_match` and an ETag-valued
  # `if_none_match` have no atomic equivalent here, and no caller uses them,
  # so they are refused rather than silently dropped.
  defp multipart_put_file(key, source, size, part_size, opts, config) do
    create_only? = Keyword.get(opts, :if_none_match) == "*"

    cond do
      Keyword.has_key?(opts, :if_match) ->
        {:error, {:multipart_unsupported_precondition, :if_match}}

      Keyword.has_key?(opts, :if_none_match) and not create_only? ->
        {:error, {:multipart_unsupported_precondition, :if_none_match}}

      true ->
        with :ok <- if(create_only?, do: precheck_absent(key, config), else: :ok),
             {:ok, upload_id} <- initiate_multipart(key, opts, config),
             {:ok, etag} <- guarded_upload(key, source, size, part_size, upload_id, create_only?, config) do
          emit_multipart(size, parts_for(size, part_size))
          {:ok, etag}
        end
    end
  end

  # Everything after initiate must end in either a completed upload or an
  # abort. Error tuples abort; so do exceptions and exits (a source file that
  # vanishes mid-upload raises from inside the request stream), which are then
  # re-raised unchanged. Only a killed process skips this, which is what the
  # bucket's incomplete-upload lifecycle rule is for.
  defp guarded_upload(key, source, size, part_size, upload_id, create_only?, config) do
    case upload_and_complete(key, source, size, part_size, upload_id, create_only?, config) do
      {:ok, _} = ok ->
        ok

      {:error, _} = error ->
        abort_multipart(key, upload_id, config)
        error
    end
  catch
    kind, reason ->
      abort_multipart(key, upload_id, config)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # A 403 on HEAD of an absent key is what AWS returns to credentials without
  # `s3:ListBucket`. It says nothing about the object, so proceed and let the
  # conditional completion decide.
  defp precheck_absent(key, config) do
    case request(:head, key, config, decode_body: false) do
      {:ok, %{status: 200}} -> {:error, :precondition_failed}
      {:ok, %{status: status}} when status in [403, 404] -> :ok
      {:ok, resp} -> {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp initiate_multipart(key, opts, config) do
    headers = maybe_header([], "content-type", Keyword.get(opts, :content_type, "application/octet-stream"))
    url = object_url(key, config) <> "?" <> URI.encode_query([{"uploads", ""}])

    case Req.request(
           build(config,
             method: :post,
             url: url,
             headers: headers,
             body: "",
             decode_body: false,
             retry: false
           )
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case extract(body, "UploadId") do
          "" -> {:error, {:multipart_no_upload_id, String.slice(body, 0, 500)}}
          upload_id -> {:ok, upload_id}
        end

      {:ok, resp} ->
        {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_and_complete(key, source, size, part_size, upload_id, create_only?, config) do
    part_count = parts_for(size, part_size)

    result =
      Enum.reduce_while(1..part_count, [], fn n, acc ->
        offset = (n - 1) * part_size
        this_size = min(part_size, size - offset)

        case upload_part(key, upload_id, n, source, offset, this_size, config) do
          {:ok, etag} -> {:cont, [{n, etag} | acc]}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:error, _} = error ->
        error

      parts when is_list(parts) ->
        complete_multipart(key, upload_id, Enum.reverse(parts), create_only?, config)
    end
  end

  defp upload_part(key, upload_id, part_number, source, offset, part_size, config) do
    url =
      object_url(key, config) <>
        "?" <> URI.encode_query([{"partNumber", Integer.to_string(part_number)}, {"uploadId", upload_id}])

    headers = [{"content-length", Integer.to_string(part_size)}]
    body = part_stream(source, offset, part_size, @chunk)

    case Req.request(
           build(config,
             method: :put,
             url: url,
             headers: headers,
             body: body,
             decode_body: false,
             retry: false
           )
         ) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        case etag(resp) do
          "" -> {:error, {:multipart_part_no_etag, part_number}}
          part_etag -> {:ok, part_etag}
        end

      {:ok, resp} ->
        {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_multipart(key, upload_id, part_etags, create_only?, config) do
    url = object_url(key, config) <> "?" <> URI.encode_query([{"uploadId", upload_id}])

    headers =
      maybe_header([{"content-type", "application/xml"}], "if-none-match", if(create_only?, do: "*"))

    config
    |> build(
      method: :post,
      url: url,
      headers: headers,
      body: complete_multipart_xml(part_etags),
      decode_body: false,
      retry: false
    )
    |> Req.request()
    |> completion_result()
  end

  # `CompleteMultipartUpload` returns the final ETag inside the XML body, not
  # as a header, and can answer 200 with an `<Error>` body when assembly failed
  # after the status line was sent; that is a failure the caller retries.
  defp completion_result({:ok, %{status: status, body: body}}) when status in 200..299 do
    cond do
      is_binary(body) and String.contains?(body, "<Error>") ->
        {:error, {:multipart_complete_error, String.slice(body, 0, 500)}}

      extract(body, "ETag") == "" ->
        {:error, {:multipart_complete_no_etag, String.slice(body, 0, 500)}}

      true ->
        {:ok, extract(body, "ETag")}
    end
  end

  # 412 is a lost create-only race. 409 is a concurrent write or delete, after
  # which S3 requires the whole upload to be started again; see
  # `resolve_conflict/4`.
  defp completion_result({:ok, %{status: 412}}), do: {:error, :precondition_failed}
  defp completion_result({:ok, %{status: 409}}), do: {:error, :conflict}

  defp completion_result({:ok, resp}), do: {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}
  defp completion_result({:error, reason}), do: {:error, reason}

  # Best-effort: the caller gets the original failure, never the abort's. A
  # failed abort is still logged, because it is the only signal that parts are
  # left for the bucket's lifecycle rule to sweep.
  defp abort_multipart(key, upload_id, config) do
    url = object_url(key, config) <> "?" <> URI.encode_query([{"uploadId", upload_id}])

    # Rescued so that an abort can never replace the error being reported.
    result =
      try do
        Req.request(build(config, method: :delete, url: url, decode_body: false, retry: false))
      rescue
        exception -> {:error, exception}
      end

    case result do
      {:ok, %{status: status}} when status in 200..299 or status == 404 ->
        :ok

      other ->
        Logger.warning("multipart upload abort failed; its parts remain until the bucket lifecycle rule",
          operation: "multipart_abort",
          object_key: key,
          upload_id: upload_id,
          outcome: abort_outcome(other)
        )

        :ok
    end
  end

  defp abort_outcome({:ok, %{status: status}}), do: "status_#{status}"
  defp abort_outcome({:error, reason}), do: inspect(reason, limit: 5)

  defp complete_multipart_xml(parts) do
    parts_xml =
      Enum.map_join(parts, "", fn {n, part_etag} ->
        "<Part><PartNumber>#{n}</PartNumber><ETag>#{part_etag}</ETag></Part>"
      end)

    "<CompleteMultipartUpload>" <> parts_xml <> "</CompleteMultipartUpload>"
  end

  # Read one part off `source` in sub-chunks, so a large part never becomes a
  # binary of its own size. The file is opened once and closed when the stream
  # halts, whether it consumed every byte or the sender raised.
  defp part_stream(source, offset, length, sub_chunk) do
    Stream.resource(
      fn ->
        io =
          case :file.open(source, [:read, :raw, :binary]) do
            {:ok, io} -> io
            {:error, reason} -> raise File.Error, reason: reason, action: "open", path: source
          end

        {:ok, _} = :file.position(io, offset)
        {io, length}
      end,
      fn
        {io, 0} ->
          {:halt, {io, 0}}

        {io, remaining} ->
          to_read = min(sub_chunk, remaining)

          case :file.read(io, to_read) do
            {:ok, data} -> {[data], {io, remaining - byte_size(data)}}
            # A file shorter than when it was measured: sending fewer bytes
            # than the declared content-length would stall or corrupt the part.
            :eof -> raise File.Error, reason: :eof, action: "read", path: source
            {:error, reason} -> raise File.Error, reason: reason, action: "read", path: source
          end
      end,
      fn {io, _} -> :file.close(io) end
    )
  end

  defp parts_for(size, part_size), do: div(size + part_size - 1, part_size)

  defp emit_multipart(size, parts) do
    :telemetry.execute(
      [:code, :object_store, :multipart_upload],
      %{bytes: size, parts: parts},
      %{}
    )
  end

  @impl true
  def get_file(key, destination, _opts, config) do
    File.mkdir_p!(Path.dirname(destination))
    partial = destination <> ".partial"

    # Written to a temporary name and renamed, so an interrupted download can
    # never be mistaken for a complete object by whatever reads it next.
    result =
      request(:get, key, config,
        into: File.stream!(partial),
        decode_body: false,
        retry: :safe_transient,
        max_retries: 2
      )

    case result do
      {:ok, %{status: 200}} ->
        File.rename!(partial, destination)
        {:ok, File.stat!(destination).size}

      {:ok, %{status: 404}} ->
        File.rm(partial)
        {:error, :not_found}

      {:ok, resp} ->
        File.rm(partial)
        {:error, {:unexpected_status, resp.status, ""}}

      {:error, reason} ->
        File.rm(partial)
        {:error, reason}
    end
  end

  @impl true
  def delete(key, config) do
    case request(:delete, key, config, decode_body: false) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, resp} -> {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list(prefix, config) do
    with {:ok, %{keys: keys}} <- list_all(prefix, config, []), do: {:ok, keys}
  end

  @impl true
  def list_prefixes(prefix, config) do
    list_all(prefix, config, [{"delimiter", "/"}])
  end

  # One ListObjectsV2 request for at most one key. Its cost is constant however
  # large the bucket is, and unlike a HEAD of an absent key it distinguishes a
  # missing bucket (404 NoSuchBucket) from a missing object.
  @impl true
  def probe(config) do
    params = [{"list-type", "2"}, {"max-keys", "1"}, {"prefix", full_key("", config)}]
    url = bucket_url(config) <> "?" <> URI.encode_query(params)

    case Req.request(
           build(config, method: :get, url: url, decode_body: false, max_retries: 1, receive_timeout: 5_000)
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, resp} -> {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stat(key, config) do
    case request(:head, key, config, decode_body: false) do
      {:ok, %{status: 200} = resp} ->
        size =
          resp
          |> Req.Response.get_header("content-length")
          |> List.first("0")
          |> String.to_integer()

        {:ok, %{etag: etag(resp), size: size}}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, resp} ->
        {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_all(prefix, config, extra) do
    list_page(prefix, config, extra, nil, {[], []})
  end

  # Pages are collected in reverse and flattened once at the end. Appending
  # each page to the accumulated list instead copies everything seen so far on
  # every page, which makes a listing quadratic in the number of pages.
  defp list_page(prefix, config, extra, token, {key_pages, prefix_pages}) do
    params =
      [{"list-type", "2"}, {"prefix", full_key(prefix, config)} | extra]
      |> then(fn p -> if token, do: p ++ [{"continuation-token", token}], else: p end)

    url = bucket_url(config) <> "?" <> URI.encode_query(params)

    case Req.request(build(config, method: :get, url: url, decode_body: false)) do
      {:ok, %{status: 200} = resp} ->
        %{keys: keys, prefixes: prefixes, next: next} = parse_list_response(resp.body, config)
        acc = {[keys | key_pages], [prefixes | prefix_pages]}

        if next do
          list_page(prefix, config, extra, next, acc)
        else
          {key_pages, prefix_pages} = acc

          {:ok,
           %{
             keys: key_pages |> Enum.reverse() |> Enum.concat(),
             prefixes: prefix_pages |> Enum.reverse() |> Enum.concat()
           }}
        end

      {:ok, resp} ->
        {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ListObjectsV2 returns XML. Rather than take an XML dependency for one call
  # site, pull out the elements we need with a scan; keys are URL-safe
  # because Code generates all of them.
  @doc false
  def parse_list_response(xml, config) do
    prefix = Keyword.get(config, :prefix, "")

    keys =
      Regex.scan(~r{<Contents>.*?</Contents>}s, xml)
      |> Enum.map(fn [chunk] ->
        %{
          key: chunk |> extract("Key") |> strip_prefix(prefix),
          size: chunk |> extract("Size") |> String.to_integer()
        }
      end)

    prefixes =
      Regex.scan(~r{<CommonPrefixes>.*?</CommonPrefixes>}s, xml)
      |> Enum.map(fn [chunk] -> chunk |> extract("Prefix") |> strip_prefix(prefix) end)

    next =
      case extract(xml, "NextContinuationToken") do
        "" -> nil
        token -> token
      end

    truncated? = extract(xml, "IsTruncated") == "true"

    %{keys: keys, prefixes: prefixes, next: if(truncated?, do: next, else: nil)}
  end

  defp extract(xml, tag) do
    case Regex.run(~r{<#{tag}>(.*?)</#{tag}>}s, xml) do
      [_, value] -> value
      nil -> ""
    end
  end

  defp strip_prefix(key, ""), do: key

  defp strip_prefix(key, prefix) do
    prefix = String.trim_trailing(prefix, "/") <> "/"
    String.replace_prefix(key, prefix, "")
  end

  defp request(method, key, config, opts) do
    Req.request(build(config, Keyword.merge(opts, method: method, url: object_url(key, config))))
  end

  defp build(config, opts) do
    Req.new(
      retry: :safe_transient,
      max_retries: 3,
      receive_timeout: Keyword.get(config, :receive_timeout, :timer.seconds(60)),
      aws_sigv4: [
        service: :s3,
        region: Keyword.get(config, :region, "auto"),
        access_key_id: Keyword.fetch!(config, :access_key_id),
        secret_access_key: Keyword.fetch!(config, :secret_access_key)
      ]
    )
    |> Req.merge(opts)
  end

  defp object_url(key, config), do: bucket_url(config) <> "/" <> encode_key(full_key(key, config))

  defp bucket_url(config) do
    endpoint = config |> Keyword.fetch!(:endpoint) |> String.trim_trailing("/")
    bucket = Keyword.fetch!(config, :bucket)

    if Keyword.get(config, :path_style, true) do
      endpoint <> "/" <> bucket
    else
      %URI{host: host} = uri = URI.parse(endpoint)
      URI.to_string(%{uri | host: bucket <> "." <> host})
    end
  end

  defp full_key(key, config) do
    case Keyword.get(config, :prefix, "") do
      "" -> key
      prefix -> String.trim_trailing(prefix, "/") <> "/" <> key
    end
  end

  # S3 keys are path segments: encode each segment but keep the separators.
  defp encode_key(key) do
    key |> String.split("/") |> Enum.map_join("/", &encode_segment/1)
  end

  defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]

  defp etag(resp) do
    resp |> Req.Response.get_header("etag") |> List.first() || ""
  end

  defp body_excerpt(%{body: body}) when is_binary(body), do: String.slice(body, 0, 500)
  defp body_excerpt(%{body: body}), do: inspect(body, limit: 20)
end
