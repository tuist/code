defmodule Code.ObjectStore.S3Test do
  @moduledoc """
  The S3 listing and readiness requests, against canned ListObjectsV2 replies.

  `Req` is stubbed because there is no S3 in the unit suite; the end-to-end
  suite exercises the same code against a real one.
  """

  use ExUnit.Case, async: true
  use Mimic

  alias Code.ObjectStore.S3

  setup :set_mimic_private
  setup :verify_on_exit!

  @config [
    bucket: "bucket",
    endpoint: "http://s3.test",
    access_key_id: "id",
    secret_access_key: "secret",
    prefix: "tenant"
  ]

  defp page(contents, prefixes, next) do
    body =
      Enum.map_join(contents, fn {key, size} ->
        "<Contents><Key>tenant/#{key}</Key><Size>#{size}</Size></Contents>"
      end) <>
        Enum.map_join(prefixes, fn prefix ->
          "<CommonPrefixes><Prefix>tenant/#{prefix}</Prefix></CommonPrefixes>"
        end)

    truncation =
      if next,
        do: "<IsTruncated>true</IsTruncated><NextContinuationToken>#{next}</NextContinuationToken>",
        else: "<IsTruncated>false</IsTruncated>"

    ~s(<?xml version="1.0"?><ListBucketResult><Prefix>tenant/repos/</Prefix>#{truncation}#{body}</ListBucketResult>)
  end

  defp query(request), do: URI.decode_query(request.url.query || "")

  defp serve(pages) do
    parent = self()

    stub(Req, :request, fn request ->
      params = query(request)
      send(parent, {:request, params})
      {:ok, %Req.Response{status: 200, body: Map.fetch!(pages, params["continuation-token"])}}
    end)
  end

  test "a paginated listing keeps every key, in order" do
    serve(%{
      nil => page([{"repos/a/index.pb", 1}, {"repos/b/index.pb", 2}], [], "t1"),
      "t1" => page([{"repos/c/index.pb", 3}], [], "t2"),
      "t2" => page([{"repos/d/index.pb", 4}], [], nil)
    })

    assert {:ok, entries} = S3.list("repos/", @config)

    assert Enum.map(entries, & &1.key) ==
             ["repos/a/index.pb", "repos/b/index.pb", "repos/c/index.pb", "repos/d/index.pb"]

    assert Enum.map(entries, & &1.size) == [1, 2, 3, 4]
    assert_received {:request, %{"prefix" => "tenant/repos/"} = first}
    refute Map.has_key?(first, "delimiter")
  end

  test "a delimiter listing returns one level: direct keys and child prefixes" do
    serve(%{
      nil => page([{"repos/acme/index.pb", 9}], ["repos/acme/app/"], "t1"),
      "t1" => page([], ["repos/acme/wal/"], nil)
    })

    assert {:ok, %{keys: [%{key: "repos/acme/index.pb", size: 9}], prefixes: prefixes}} =
             S3.list_prefixes("repos/acme/", @config)

    assert prefixes == ["repos/acme/app/", "repos/acme/wal/"]
    assert_received {:request, %{"delimiter" => "/"}}
  end

  test "the readiness probe is a single request for at most one key" do
    parent = self()

    stub(Req, :request, fn request ->
      send(parent, {:request, query(request)})
      {:ok, %Req.Response{status: 200, body: page([], [], nil)}}
    end)

    assert :ok = S3.probe(@config)
    assert_received {:request, %{"max-keys" => "1", "list-type" => "2"}}
    refute_received {:request, _}
  end

  test "the readiness probe fails when the bucket cannot be used" do
    stub(Req, :request, fn _request ->
      {:ok, %Req.Response{status: 404, body: "<Error><Code>NoSuchBucket</Code></Error>"}}
    end)

    assert {:error, {:unexpected_status, 404, _}} = S3.probe(@config)
  end

  describe "put_file/4 above the multipart threshold" do
    @mib 1024 * 1024
    @multipart_config @config ++ [multipart_threshold: 5 * @mib, multipart_part_size: 5 * @mib]

    @describetag :tmp_dir
    setup :tmp_file

    defp tmp_file(%{tmp_dir: tmp} = context) do
      path = Path.join(tmp, "pack")
      size = Map.get(context, :size, 12 * @mib + 7)

      if size > 64 * @mib do
        # Sparse, so a test can describe a many-gibibyte pack without writing one.
        {:ok, fd} = :file.open(path, [:write, :raw, :binary])
        :ok = :file.pwrite(fd, size - 1, <<0>>)
        :ok = :file.close(fd)
      else
        File.write!(path, :binary.copy(<<7>>, size))
      end

      {:ok, source: path}
    end

    # A fake S3 that answers each multipart request by kind, reads every
    # streamed body the way the HTTP client would, and reports what it saw.
    defp fake_s3(overrides \\ %{}) do
      parent = self()

      stub(Req, :request, fn request ->
        kind = kind(request)
        bytes = consume(request.body)

        send(
          parent,
          {:s3, kind, %{bytes: bytes, if_none_match: Req.Request.get_header(request, "if-none-match")}}
        )

        case Map.get(overrides, kind) || Map.get(overrides, elem_kind(kind)) do
          nil -> default_response(kind)
          respond -> respond.(request)
        end
      end)
    end

    defp kind(%{method: method} = request) do
      params = query(request)

      case {method, Map.keys(params) |> Enum.sort()} do
        {:head, _} -> :head
        {:post, ["uploads"]} -> :initiate
        {:put, ["partNumber", "uploadId"]} -> {:part, String.to_integer(params["partNumber"])}
        {:post, ["uploadId"]} -> :complete
        {:delete, ["uploadId"]} -> :abort
        {:put, []} -> :put
      end
    end

    defp elem_kind({:part, _}), do: :part
    defp elem_kind(kind), do: kind

    defp consume(nil), do: 0
    defp consume(body) when is_binary(body), do: byte_size(body)
    defp consume(stream), do: Enum.reduce(stream, 0, &(byte_size(&1) + &2))

    defp default_response(:head), do: {:ok, %Req.Response{status: 404, body: ""}}

    defp default_response(:initiate),
      do:
        {:ok,
         %Req.Response{
           status: 200,
           body: "<InitiateMultipartUploadResult><UploadId>up-1</UploadId></InitiateMultipartUploadResult>"
         }}

    defp default_response({:part, n}),
      do: {:ok, %Req.Response{status: 200, headers: %{"etag" => [~s("part-#{n}")]}, body: ""}}

    defp default_response(:complete),
      do:
        {:ok,
         %Req.Response{
           status: 200,
           body: ~s(<CompleteMultipartUploadResult><ETag>"final-3"</ETag></CompleteMultipartUploadResult>)
         }}

    defp default_response(:abort), do: {:ok, %Req.Response{status: 204, body: ""}}

    defp default_response(:put),
      do: {:ok, %Req.Response{status: 200, headers: %{"etag" => [~s("single")]}, body: ""}}

    defp status(code, body \\ ""), do: fn _ -> {:ok, %Req.Response{status: code, body: body}} end

    @tag size: 5 * 1024 * 1024
    test "a file exactly at the threshold is one conditional PUT", %{source: source} do
      fake_s3()

      assert {:ok, ~s("single")} =
               S3.put_file("packs/p.pack", source, [if_none_match: "*"], @multipart_config)

      assert_received {:s3, :put, %{bytes: 5_242_880, if_none_match: ["*"]}}
      refute_received {:s3, _, _}
    end

    test "streams every part and completes create-only", %{source: source} do
      fake_s3()

      assert {:ok, ~s("final-3")} =
               S3.put_file("packs/p.pack", source, [if_none_match: "*"], @multipart_config)

      assert_received {:s3, :head, _}
      assert_received {:s3, :initiate, _}
      assert_received {:s3, {:part, 1}, %{bytes: 5_242_880}}
      assert_received {:s3, {:part, 2}, %{bytes: 5_242_880}}
      assert_received {:s3, {:part, 3}, %{bytes: 2_097_159}}
      # Create-only is enforced by the store at completion, not by the HEAD.
      assert_received {:s3, :complete, %{if_none_match: ["*"]}}
      refute_received {:s3, _, _}
    end

    @tag size: 10 * 1024 * 1024
    test "a size divisible by the part size has no empty trailing part", %{source: source} do
      fake_s3()

      assert {:ok, _} = S3.put_file("packs/p.pack", source, [], @multipart_config)
      assert_received {:s3, {:part, 2}, %{bytes: 5_242_880}}
      refute_received {:s3, {:part, 3}, _}
      assert_received {:s3, :complete, %{if_none_match: []}}
    end

    test "an object already present is reported without sending a byte", %{source: source} do
      fake_s3(%{head: status(200)})

      assert {:error, :precondition_failed} =
               S3.put_file("packs/p.pack", source, [if_none_match: "*"], @multipart_config)

      refute_received {:s3, :initiate, _}
    end

    test "a 403 on the pre-check is not taken as an answer", %{source: source} do
      # AWS answers HEAD of an absent key with 403 to credentials without
      # s3:ListBucket; the conditional completion still arbitrates.
      fake_s3(%{head: status(403)})

      assert {:ok, _} = S3.put_file("packs/p.pack", source, [if_none_match: "*"], @multipart_config)
      assert_received {:s3, :complete, %{if_none_match: ["*"]}}
    end

    test "losing the create-only race at completion aborts and reports it", %{source: source} do
      fake_s3(%{complete: status(412)})

      assert {:error, :precondition_failed} =
               S3.put_file("packs/p.pack", source, [if_none_match: "*"], @multipart_config)

      assert_received {:s3, :abort, _}
    end

    test "a failed part aborts the upload and returns the part's error", %{source: source} do
      fake_s3(%{{:part, 2} => status(500, "slow down")})

      assert {:error, {:unexpected_status, 500, "slow down"}} =
               S3.put_file("packs/p.pack", source, [], @multipart_config)

      refute_received {:s3, {:part, 3}, _}
      refute_received {:s3, :complete, _}
      assert_received {:s3, :abort, _}
    end

    test "a part answered without an ETag aborts", %{source: source} do
      fake_s3(%{{:part, 1} => status(200)})

      assert {:error, {:multipart_part_no_etag, 1}} =
               S3.put_file("packs/p.pack", source, [], @multipart_config)

      assert_received {:s3, :abort, _}
    end

    test "a completion that fails after a 200 status aborts", %{source: source} do
      fake_s3(%{complete: status(200, "<Error><Code>InternalError</Code></Error>")})

      assert {:error, {:multipart_complete_error, _}} =
               S3.put_file("packs/p.pack", source, [], @multipart_config)

      assert_received {:s3, :abort, _}
    end

    test "an initiate without an upload id has nothing to abort", %{source: source} do
      fake_s3(%{initiate: status(200, "<InitiateMultipartUploadResult/>")})

      assert {:error, {:multipart_no_upload_id, _}} =
               S3.put_file("packs/p.pack", source, [], @multipart_config)

      refute_received {:s3, :abort, _}
    end

    test "a source that vanishes mid-upload still aborts, and the exception surfaces", %{source: source} do
      fake_s3(%{
        {:part, 1} => fn _ ->
          File.rm!(source)
          default_response({:part, 1})
        end
      })

      assert_raise File.Error, fn -> S3.put_file("packs/p.pack", source, [], @multipart_config) end
      assert_received {:s3, :abort, _}
      refute_received {:s3, :complete, _}
    end

    test "an abort that fails is logged, and the original error still returned", %{source: source} do
      fake_s3(%{{:part, 1} => status(500), abort: status(403)})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:unexpected_status, 500, _}} =
                   S3.put_file("packs/p.pack", source, [], @multipart_config)
        end)

      assert log =~ "multipart upload abort failed"
    end

    test "a 409 at completion is a conflict unless the object is really there", %{source: source} do
      fake_s3(%{complete: status(409, "<Error><Code>ConditionalRequestConflict</Code></Error>")})

      assert {:error, {:conflict, 409}} =
               S3.put_file("packs/p.pack", source, [if_none_match: "*"], @multipart_config)

      assert_received {:s3, :abort, _}
    end

    test "a 409 at completion with the object present is the create-only answer", %{source: source} do
      # The pre-check sees nothing; by the time the conflict is resolved the
      # other writer's object exists.
      fake_s3(%{
        complete: status(409),
        head: fn _ ->
          seen = Process.get(:heads, 0)
          Process.put(:heads, seen + 1)
          {:ok, %Req.Response{status: if(seen == 0, do: 404, else: 200), body: ""}}
        end
      })

      assert {:error, :precondition_failed} =
               S3.put_file("packs/p.pack", source, [if_none_match: "*"], @multipart_config)
    end

    @tag size: 1024
    test "a 409 on a single PUT is resolved the same way", %{source: source} do
      fake_s3(%{put: status(409)})

      assert {:error, {:conflict, 409}} =
               S3.put_file("packs/p.pack", source, [if_none_match: "*"], @multipart_config)

      fake_s3(%{put: status(409), head: status(200)})

      assert {:error, :precondition_failed} =
               S3.put_file("packs/p.pack", source, [if_none_match: "*"], @multipart_config)
    end

    @tag size: 5 * 1024 * 1024 * 1024 + 1
    test "a file above the single-PUT limit is multipart however high the threshold", %{source: source} do
      fake_s3(%{{:part, 1} => status(500)})
      config = Keyword.put(@multipart_config, :multipart_threshold, 10 * 1024 * @mib)

      assert {:error, {:unexpected_status, 500, _}} = S3.put_file("packs/p.pack", source, [], config)
      assert_received {:s3, :initiate, _}
      refute_received {:s3, :put, _}
    end

    @tag size: 5 * 1024 * 1024 * 10_000 + 1
    test "a file beyond part size times 10,000 is refused before any request", %{source: source} do
      fake_s3()

      assert {:error, {:object_too_large, "packs/p.pack", _, 52_428_800_000}} =
               S3.put_file("packs/p.pack", source, [], @multipart_config)

      refute_received {:s3, _, _}
    end

    test "an abort that raises does not replace the original error", %{source: source} do
      fake_s3(%{{:part, 1} => status(500), abort: fn _ -> raise "abort blew up" end})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:unexpected_status, 500, _}} =
                   S3.put_file("packs/p.pack", source, [], @multipart_config)
        end)

      assert log =~ "multipart upload abort failed"
    end

    test "preconditions with no atomic multipart equivalent are refused up front", %{source: source} do
      fake_s3()

      assert {:error, {:multipart_unsupported_precondition, :if_match}} =
               S3.put_file("packs/p.pack", source, [if_match: ~s("e")], @multipart_config)

      assert {:error, {:multipart_unsupported_precondition, :if_none_match}} =
               S3.put_file("packs/p.pack", source, [if_none_match: ~s("e")], @multipart_config)

      refute_received {:s3, _, _}
    end

    test "a part size S3 would reject fails before any request", %{source: source} do
      fake_s3()

      for part_size <- [5 * @mib - 1, 5 * 1024 * @mib + 1] do
        config = Keyword.put(@multipart_config, :multipart_part_size, part_size)

        assert {:error, {:invalid_multipart_part_size, ^part_size, _, _}} =
                 S3.put_file("packs/p.pack", source, [], config)
      end

      refute_received {:s3, _, _}
    end
  end
end
