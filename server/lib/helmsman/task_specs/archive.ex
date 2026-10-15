defmodule Helmsman.TaskSpecs.Archive do
  @moduledoc """
  OpenSpec change directories as `tar.gz` or `zip` (`add-spec-workflow`
  decision 18), built and read in memory with OTP's `:erl_tar`, `:zip`
  and `:zlib` only; nothing is written to disk and nothing is executed.

  Export: `<change_id>/.openspec.yaml`, the version's files and (with
  `reviews: true`) `<change_id>/reviews/spec-review-<n>.md`, sorted by
  path, every entry stamped with the first version's time, so that two
  exports of a version are identical.

  Import: the archive (≤ 2 MB; ≤ 200 entries; ≤ 1 MB declared and
  actual) holds regular files and directories only, with relative names
  without `..`. Without the common directory prefix, the allowed paths
  replace every file of `base_version` as a new version; `.openspec.yaml`
  and `reviews/**` are ignored, other paths come back as `warnings`.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.TaskSpecs
  alias Helmsman.TaskSpecs.{Diff, Files}

  @max_archive_bytes 2 * 1024 * 1024
  @max_entries 200
  @max_content_bytes 1024 * 1024
  # A tar of 200 entries of 1 MB in all: headers and padding included.
  @max_tar_bytes @max_content_bytes + @max_entries * 2 * 512 + 2 * 512 + 10_240
  @formats %{"tar.gz" => "application/gzip", "zip" => "application/zip"}

  @doc "The largest archive `import/4` accepts, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_archive_bytes

  ## Export

  @doc """
  The archive of a version (`opts`: `version` (default the latest),
  `format` (`"tar.gz"`, default, or `"zip"`), `reviews` (default false)):
  `{:ok, %{filename, content_type, body}}`.
  """
  @spec export(Scope.t(), String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def export(%Scope{} = scope, ident, opts) do
    opts = Map.new(opts)
    format = Map.get(opts, :format) || "tar.gz"

    with :ok <- known_format(format),
         {:ok, reviews?} <- boolean_option(opts, :reviews),
         {:ok, %{version: %{} = version} = spec} <-
           TaskSpecs.get(scope, ident, version: opts[:version]),
         {:ok, reviews} <- export_reviews(scope, ident, reviews?, version.number) do
      first = hd(spec.versions)
      change_id = spec.spec.change_id
      mtime = DateTime.to_unix(first.at)

      entries =
        [{".openspec.yaml", openspec_yaml(first.at)}]
        |> Kernel.++(for file <- version.files, do: {file.path, file.content})
        |> Kernel.++(for review <- reviews, do: {review_path(review), review_markdown(review)})
        |> Enum.map(fn {path, content} -> {"#{change_id}/#{path}", content} end)
        |> Enum.sort()

      {:ok,
       %{
         filename: "#{change_id}-v#{version.number}.#{format}",
         content_type: @formats[format],
         body: pack(format, entries, mtime)
       }}
    else
      {:ok, %{version: nil}} -> {:error, {:spec, :no_version}}
      {:error, _reason} = error -> error
    end
  end

  defp known_format(format) when is_map_key(@formats, format), do: :ok

  defp known_format(_format),
    do: {:error, {:spec, :invalid_params, %{field: :format, message: "must be tar.gz or zip"}}}

  defp boolean_option(opts, key) do
    case Map.get(opts, key) do
      value when value in [nil, false, "false"] -> {:ok, false}
      value when value in [true, "true"] -> {:ok, true}
      _other -> {:error, {:spec, :invalid_params, %{field: key, message: "must be a boolean"}}}
    end
  end

  defp export_reviews(_scope, _ident, false, _version), do: {:ok, []}

  defp export_reviews(scope, ident, true, version) do
    with {:ok, %{reviews: reviews}} <- TaskSpecs.reviews(scope, ident),
         do: {:ok, Enum.filter(reviews, &(&1.version <= version))}
  end

  defp openspec_yaml(at),
    do: "schema: spec-driven\ncreated: #{Date.to_iso8601(DateTime.to_date(at))}\n"

  defp review_path(review), do: "reviews/spec-review-#{review.number}.md"

  @doc false
  # The Markdown of a review (decision 18's template).
  def review_markdown(review) do
    head = [
      "# Spec review R#{review.number} — version #{review.version}\n\n",
      "Reviewer: #{review.reviewer}\n",
      "Verdict: #{review.verdict}\n",
      paragraph(review.summary)
    ]

    IO.iodata_to_binary([head | Enum.map(review.issues, &issue_markdown/1)])
  end

  defp issue_markdown(issue) do
    location =
      case {issue.file, issue.line} do
        {nil, _line} -> nil
        {file, nil} -> file
        {file, line} -> "#{file}:#{line}"
      end

    title =
      Enum.reject(["## #{issue.ref} [#{issue.severity}]", location, issue.anchor], &blank?/1)

    notes =
      for note <- issue.notes do
        "- #{note.author} (#{note.resolution || note.kind}): #{indent(note.body)}\n"
      end

    [
      "\n",
      Enum.join(title, " "),
      "\n\nStatus: #{issue.resolution}\n",
      paragraph(issue.body),
      if(blank?(issue.suggestion), do: [], else: paragraph("Suggestion: " <> issue.suggestion)),
      if(notes == [], do: [], else: ["\n" | notes])
    ]
  end

  defp paragraph(text) do
    if blank?(text), do: [], else: ["\n", String.trim_trailing(text), "\n"]
  end

  defp indent(nil), do: ""
  defp indent(text), do: text |> String.trim_trailing() |> String.replace("\n", "\n  ")

  defp blank?(value), do: value in [nil, ""]

  defp pack("tar.gz", entries, mtime) do
    {:ok, fd} = :file.open("", [:ram, :read, :write, :binary])

    try do
      {:ok, tar} = :erl_tar.init(fd, :write, &ram_file/2)

      for {name, content} <- entries,
          do: :ok = :erl_tar.add(tar, content, String.to_charlist(name), mtime: mtime)

      :ok = :erl_tar.close(tar)
      {:ok, size} = :file.position(fd, :cur)
      {:ok, data} = :file.pread(fd, 0, size)
      :zlib.gzip(data)
    after
      :file.close(fd)
    end
  end

  defp pack("zip", entries, mtime) do
    time = mtime |> DateTime.from_unix!() |> DateTime.to_naive() |> NaiveDateTime.to_erl()

    files =
      for {name, content} <- entries do
        info =
          File.Stat.to_record(%File.Stat{
            size: byte_size(content),
            type: :regular,
            access: :read_write,
            atime: time,
            mtime: time,
            ctime: time,
            mode: 0o100644,
            links: 1,
            major_device: 0,
            minor_device: 0,
            inode: 0,
            uid: 0,
            gid: 0
          })

        {String.to_charlist(name), content, info}
      end

    {:ok, {_name, body}} = :zip.create(~c"spec.zip", files, [:memory])
    body
  end

  # `:erl_tar.init/3`'s file operations on a RAM file the caller closes.
  defp ram_file(:write, {fd, data}), do: :file.write(fd, data)
  defp ram_file(:position, {fd, position}), do: :file.position(fd, position)
  defp ram_file(:read2, {fd, size}), do: :file.read(fd, size)
  defp ram_file(:close, _fd), do: :ok

  ## Import

  @doc """
  Submits the archive `binary` as a new version (`opts`: `base_version`
  (required), `note`, `dry_run`). Returns `submit_version/3`'s result
  with `warnings` (the ignored paths); a dry run also has `dry_run`,
  `base_version`, `change_id` (the one the first version would use, nil
  afterwards) and `diff` (from `base_version` to the archive).
  """
  @spec import(Scope.t(), String.t(), binary(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def import(%Scope{} = scope, ident, binary, opts) when is_binary(binary) do
    opts = Map.new(opts)
    base = Map.get(opts, :base_version)

    with {:ok, dry_run?} <- boolean_option(opts, :dry_run),
         {:ok, entries} <- read(binary),
         {:ok, prefix, files, warnings} <- sort(entries),
         {:ok, base_files} <- base_files(scope, ident, base) do
      attrs = %{
        base_version: base,
        files: files,
        remove: Map.keys(base_files) -- Map.keys(files),
        note: Map.get(opts, :note) || "",
        change_id_hint: prefix && List.last(prefix),
        dry_run: dry_run?
      }

      with {:ok, result} <- TaskSpecs.submit_version(scope, ident, attrs) do
        result = Map.put(result, :warnings, warnings)
        {:ok, if(dry_run?, do: preview(result, base, base_files, files), else: result)}
      end
    end
  end

  defp preview(result, base, base_files, files) do
    result
    |> Map.merge(%{
      dry_run: true,
      base_version: base,
      diff: Map.merge(%{from: base, to: nil}, Diff.run(base_files, files))
    })
    |> Map.put_new(:change_id, nil)
  end

  # The files of `base_version`; an unknown one is left to
  # `submit_version/3` (`stale_version`).
  defp base_files(_scope, _ident, base) when not is_integer(base) or base <= 0, do: {:ok, %{}}

  defp base_files(scope, ident, base) do
    case TaskSpecs.get(scope, ident, version: base) do
      {:ok, %{version: %{files: files}}} ->
        {:ok, Map.new(files, &{&1.path, &1.content})}

      {:error, {:spec, reason, _detail}} when reason in [:not_found, :version_not_found] ->
        {:ok, %{}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  # `{:ok, [{name, content}]}` of the regular files of an archive.
  def read(binary) when byte_size(binary) > @max_archive_bytes,
    do: invalid("the archive is larger than 2 MB")

  def read(<<0x1F, 0x8B, _rest::binary>> = binary) do
    with {:ok, tar} <- gunzip(binary),
         {:ok, table} <- tar_table(tar),
         :ok <- check(Enum.map(table, &tar_entry/1)) do
      case :erl_tar.extract({:binary, tar}, [:memory]) do
        {:ok, files} -> contents(files)
        {:error, _reason} -> invalid("the tar file is damaged")
      end
    end
  end

  # Read here, not with `:zip.unzip/2`: that extracts by the local
  # headers' names (making absolute ones relative) and inflates every
  # entry whole whatever the central directory declares.
  def read(<<"PK", 3, 4, _rest::binary>> = binary) do
    with {:ok, listing} <- zip_listing(binary),
         :ok <- check(listing),
         {:ok, files} <- zip_extract(binary, listing) do
      contents(files)
    end
  end

  def read(_binary), do: invalid("the upload is not a tar.gz or zip archive")

  # Inflates at most what 200 entries of 1 MB need, so a small archive
  # cannot expand without bound.
  defp gunzip(binary) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      inflate(z, :zlib.safeInflate(z, binary), [], 0)
    rescue
      _error -> invalid("the gzip data is damaged")
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, {status, output}, acc, size) do
    size = size + IO.iodata_length(output)
    acc = [acc | output]

    cond do
      size > @max_tar_bytes -> invalid("the archive holds more than 1 MB")
      status == :finished -> {:ok, IO.iodata_to_binary(acc)}
      true -> inflate(z, :zlib.safeInflate(z, []), acc, size)
    end
  end

  defp tar_table(tar) do
    case :erl_tar.table({:binary, tar}, [:verbose]) do
      {:ok, table} -> {:ok, table}
      {:error, _reason} -> invalid("the tar file is damaged")
    end
  end

  defp tar_entry({name, type, size, _mtime, _mode, _uid, _gid}),
    do: %{name: name, type: type, size: size}

  # The central directory as written, read here rather than with
  # `:zip.list_dir/1`, which silently makes absolute names relative.
  defp zip_listing(binary) do
    with {:ok, count, offset} <- end_of_directory(binary),
         {:ok, entries} <- directory(binary, offset, count, []) do
      {:ok, entries}
    else
      _error -> invalid("the zip file is damaged")
    end
  end

  defp end_of_directory(binary) do
    case :binary.matches(binary, <<"PK", 5, 6>>) do
      [] ->
        :error

      matches ->
        {at, _length} = List.last(matches)

        case binary_part(binary, at, byte_size(binary) - at) do
          <<"PK", 5, 6, _disks::binary-4, _here::16-little, count::16-little, _size::32-little,
            offset::32-little, _rest::binary>> ->
            {:ok, count, offset}

          _other ->
            :error
        end
    end
  end

  defp directory(_binary, _offset, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp directory(binary, offset, count, acc) when offset < byte_size(binary) do
    case binary_part(binary, offset, byte_size(binary) - offset) do
      <<"PK", 1, 2, _version, made_by, _needed::16, flags::16-little, method::16-little,
        _time::16, _date::16, crc::32-little, compressed::32-little, size::32-little,
        name_length::16-little, extra_length::16-little, comment_length::16-little, _disk::16,
        _internal::16, external::32-little, local::32-little, name::binary-size(name_length),
        _rest::binary>> ->
        mode = if made_by == 3, do: Bitwise.bsr(external, 16), else: 0

        entry = %{
          name: name,
          type: zip_type(name, mode),
          size: size,
          compressed: compressed,
          method: method,
          flags: flags,
          crc: crc,
          local: local
        }

        next = offset + 46 + name_length + extra_length + comment_length
        directory(binary, next, count - 1, [entry | acc])

      _other ->
        :error
    end
  end

  defp directory(_binary, _offset, _count, _acc), do: :error

  # Every entry's local header must repeat its central directory name,
  # method and flags; file contents are inflated within what is left of
  # the 1 MB budget and must have the declared size and CRC.
  defp zip_extract(binary, listing) do
    listing
    |> Enum.reduce_while({:ok, [], 0}, fn entry, {:ok, files, used} ->
      case zip_entry(binary, entry, @max_content_bytes - used) do
        {:ok, nil} -> {:cont, {:ok, files, used}}
        {:ok, content} -> {:cont, {:ok, [{entry.name, content} | files], used + entry.size}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files, _used} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp zip_entry(_binary, %{flags: flags} = entry, _budget) when Bitwise.band(flags, 1) == 1,
    do: invalid("#{name(entry.name)} is encrypted")

  defp zip_entry(_binary, %{size: size} = entry, _budget)
       when size == 0xFFFFFFFF or entry.compressed == 0xFFFFFFFF or entry.local == 0xFFFFFFFF,
       do: invalid("#{name(entry.name)} needs ZIP64, which is not supported")

  defp zip_entry(binary, entry, budget) do
    with {:ok, data} <- local_data(binary, entry) do
      cond do
        entry.type == :directory -> {:ok, nil}
        entry.size > budget -> invalid("the archive holds more than 1 MB")
        true -> entry_content(entry, data, budget)
      end
    end
  end

  defp local_data(binary, entry) do
    compressed = entry.compressed

    rest =
      if entry.local < byte_size(binary),
        do: binary_part(binary, entry.local, byte_size(binary) - entry.local),
        else: <<>>

    case rest do
      <<"PK", 3, 4, _needed::16, flags::16-little, method::16-little, _time::16, _date::16,
        _crc::32, _compressed::32, _size::32, name_length::16-little, extra_length::16-little,
        name::binary-size(name_length), _extra::binary-size(extra_length),
        data::binary-size(^compressed), _rest::binary>> ->
        if name == entry.name and method == entry.method and flags == entry.flags,
          do: {:ok, data},
          else: invalid("#{name(name)} does not match the zip's central directory")

      _other ->
        invalid("the zip file is damaged")
    end
  end

  defp entry_content(%{method: 0} = entry, data, _budget), do: verify(entry, data)

  defp entry_content(%{method: 8} = entry, data, budget) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)

      case inflate_raw(z, :zlib.safeInflate(z, data), [], 0, budget) do
        {:ok, content} -> verify(entry, content)
        error -> error
      end
    rescue
      _error -> invalid("the zip file is damaged")
    after
      :zlib.close(z)
    end
  end

  defp entry_content(entry, _data, _budget),
    do: invalid("#{name(entry.name)} uses an unsupported compression method")

  defp inflate_raw(z, {status, output}, acc, size, budget) do
    size = size + IO.iodata_length(output)
    acc = [acc | output]

    cond do
      size > budget -> invalid("the archive holds more than 1 MB")
      status == :finished -> {:ok, IO.iodata_to_binary(acc)}
      true -> inflate_raw(z, :zlib.safeInflate(z, []), acc, size, budget)
    end
  end

  defp verify(entry, content) do
    if byte_size(content) == entry.size and :erlang.crc32(content) == entry.crc,
      do: {:ok, content},
      else: invalid("#{name(entry.name)} does not have its declared size or checksum")
  end

  # The Unix file type a zip records (`made_by` 3), else by the name.
  defp zip_type(name, mode) do
    case Bitwise.band(mode, 0o170000) do
      0o100000 -> :regular
      0o040000 -> :directory
      0 -> if String.ends_with?(name, "/"), do: :directory, else: :regular
      _other -> :other
    end
  end

  defp check(entries) do
    cond do
      length(entries) > @max_entries ->
        invalid("the archive has more than #{@max_entries} entries")

      bad = Enum.find(entries, &(&1.type not in [:regular, :directory])) ->
        invalid("#{name(bad.name)} is not a regular file or directory")

      bad = Enum.find(entries, &(not safe_name?(&1.name))) ->
        invalid("#{name(bad.name)} is an absolute path or contains ..")

      Enum.sum(Enum.map(entries, & &1.size)) > @max_content_bytes ->
        invalid("the archive holds more than 1 MB")

      true ->
        :ok
    end
  end

  defp safe_name?(name) do
    case to_string_name(name) do
      {:ok, "/" <> _rest} -> false
      {:ok, string} -> ".." not in String.split(string, ["/", "\\"])
      :error -> false
    end
  end

  defp name(name) do
    case to_string_name(name) do
      {:ok, string} -> inspect(string)
      :error -> "An entry"
    end
  end

  defp to_string_name(name) do
    string = IO.chardata_to_string(name)
    if String.valid?(string), do: {:ok, string}, else: :error
  rescue
    _error -> :error
  end

  defp contents(files) do
    files =
      for {name, content} <- files,
          {:ok, name} = to_string_name(name),
          not String.ends_with?(name, "/"),
          do: {String.trim_leading(name, "./"), content}

    if Enum.sum(Enum.map(files, fn {_name, content} -> byte_size(content) end)) >
         @max_content_bytes,
       do: invalid("the archive holds more than 1 MB"),
       else: {:ok, files}
  end

  @doc false
  # Removes the longest common directory prefix that leaves an allowed
  # path, then sorts: `{:ok, prefix_segments | nil, %{path => content},
  # warnings}`.
  def sort(entries) do
    names = Enum.map(entries, &elem(&1, 0))
    common = common_prefix(names)

    prefix =
      Enum.find(length(common)..0//-1, 0, fn n ->
        Enum.any?(names, &Files.allowed_path?(strip(&1, n)))
      end)

    {files, warnings} =
      Enum.reduce(entries, {%{}, []}, fn {name, content}, {files, warnings} ->
        path = strip(name, prefix)

        cond do
          Files.allowed_path?(path) -> {Map.put(files, path, content), warnings}
          ignored?(path) -> {files, warnings}
          true -> {files, [path | warnings]}
        end
      end)

    if map_size(files) == 0,
      do: invalid("the archive has no spec file (proposal.md, specs/<capability>/spec.md, ...)"),
      else: {:ok, if(prefix > 0, do: Enum.take(common, prefix)), files, Enum.sort(warnings)}
  end

  defp common_prefix([]), do: []

  defp common_prefix(names) do
    names
    |> Enum.map(&(&1 |> String.split("/") |> Enum.drop(-1)))
    |> Enum.reduce(fn dirs, acc ->
      dirs |> Enum.zip(acc) |> Enum.take_while(fn {a, b} -> a == b end) |> Enum.map(&elem(&1, 0))
    end)
  end

  defp strip(name, n), do: name |> String.split("/") |> Enum.drop(n) |> Enum.join("/")

  defp ignored?(".openspec.yaml"), do: true
  defp ignored?("reviews/" <> _rest), do: true
  defp ignored?(_path), do: false

  defp invalid(message), do: {:error, {:spec, :invalid_archive, message}}
end
