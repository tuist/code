Logger.configure(level: :warning)
endpoint = System.fetch_env!("AUTO_S3_ENDPOINT")
root = System.fetch_env!("AUTO_S3_ROOT")
bucket = "auto-s3-#{System.pid()}"

config = [
  endpoint: endpoint,
  bucket: bucket,
  access_key_id: "code",
  secret_access_key: "code-secret",
  region: "us-east-1",
  path_style: true,
  multipart_threshold: 5 * 1024 * 1024,
  multipart_part_size: 5 * 1024 * 1024
]

{:ok, %{status: 200}} =
  Req.request(
    method: :put,
    url: endpoint <> "/" <> bucket,
    decode_body: false,
    aws_sigv4: [service: :s3, region: "us-east-1", access_key_id: "code", secret_access_key: "code-secret"]
  )

Code.Config.put_overrides(%{
  object_store: {Code.ObjectStore.S3, config},
  data_dir: Path.join(root, "data"),
  node_id: "auto-s3-validation"
})

repos =
  for isolated <- [false, true] do
    Code.Config.put_overrides(Map.put(Code.Config.overrides(), :recovery_enabled, isolated))
    repo = "autos3#{System.pid()}/#{if isolated, do: "isolated", else: "legacy"}"
    {:ok, _} = Code.Control.create_repository(repo)
    repo
  end

try do
  tips =
    for repo <- repos do
      tip =
        Enum.reduce(1..4, Code.WAL.Entry.zero_oid(), fn n, old ->
          {:ok, view} = Code.Replica.ensure_fresh(repo)
          content = "version #{n}\n" <> String.duplicate("real source line\n", n * 64)
          {:ok, blob} = Code.Git.write_blob(view.path, content)

          {:ok, tree} =
            Code.Git.write_tree(view.path, if(n == 1, do: nil, else: old), [%{path: "source.txt", oid: blob}])

          {:ok, commit} =
            Code.Git.commit_tree(view.path, tree, if(n == 1, do: [], else: [old]), "change #{n}", %{
              name: "S3 Holdout",
              email: "s3@example.com"
            })

          {:ok, _} =
            Code.Ingest.update_refs_raw(repo, [Code.WAL.Entry.command("refs/heads/main", old, commit)])

          commit
        end)

      {:ok, _} =
        Code.Ingest.update_refs_raw(repo, [
          Code.WAL.Entry.command("refs/heads/feature", Code.WAL.Entry.zero_oid(), tip)
        ])

      {:ok, _} =
        Code.Ingest.update_refs_raw(repo, [
          Code.WAL.Entry.command("refs/heads/feature", tip, Code.WAL.Entry.zero_oid())
        ])

      tip
    end

  for {repo, tip} <- Enum.zip(repos, tips) do
    :ok = Code.Replica.evict(repo)
    {:ok, view} = Code.Replica.ensure_fresh(repo)
    {:ok, ^tip} = Code.Git.resolve(view.path, "HEAD")
    {:ok, refs} = Code.Git.refs(view.path)
    true = refs == %{"refs/heads/main" => tip}
    {:ok, content} = Code.Git.read_file(view.path, "HEAD", "source.txt")
    true = String.starts_with?(content, "version 4\n")
    {:ok, _} = Code.Git.run(view.path, ["fsck", "--strict", "--no-dangling"])
    clone = Path.join(root, "clone-#{Path.basename(repo)}")
    {_, 0} = System.cmd("git", ["clone", "--no-local", "--bare", view.path, clone], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["--git-dir", clone, "fsck", "--strict", "--no-dangling"], stderr_to_stdout: true)
  end

  # An independent incompressible multipart transfer exercises the real wire
  # path; this is a raw fixture, never an in-memory packfile.
  source = Path.join(root, "multipart-source")
  destination = Path.join(root, "multipart-output")
  chunk = :crypto.strong_rand_bytes(64 * 1024)
  {:ok, file} = :file.open(source, [:raw, :binary, :write])
  for _ <- 1..97, do: :ok = :file.write(file, chunk)
  :ok = :file.close(file)
  {:ok, wanted, bytes} = Code.ObjectStore.digest_file(source)
  {:ok, etag} = Code.ObjectStore.put_file("holdout/multipart", source, if_none_match: "*")
  {:error, :precondition_failed} = Code.ObjectStore.put_file("holdout/multipart", source, if_none_match: "*")
  {:ok, ^bytes} = Code.ObjectStore.get_file("holdout/multipart", destination)
  {:ok, ^wanted, ^bytes} = Code.ObjectStore.digest_file(destination)
  {:ok, head} = Code.ObjectStore.stat("holdout/multipart")
  IO.inspect(%{completion_etag: etag, head_etag: head.etag}, label: "S3_ETAG")
  true = etag == head.etag
  {:ok, :not_modified} = Code.ObjectStore.get("holdout/multipart", etag: etag)

  IO.puts(
    "S3_HOLDOUT passed legacy+isolated commits/ref-only/cache-loss/real-clone/fsck and multipart/create-only/conditional304/fullSHA256 bytes=#{bytes}"
  )
after
  for repo <- repos, do: Code.Replica.evict(repo)
end
