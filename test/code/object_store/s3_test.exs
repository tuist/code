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
end
