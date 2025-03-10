defmodule Burrito.Builder.Target do
  use TypedStruct

  alias __MODULE__
  alias Burrito.Builder.Log
  alias Burrito.Util

  @type erts_source :: {:runtime | :precompiled | :local | :local_unpacked | :url, keyword()}

  @old_targets [:darwin, :win64, :linux, :linux_musl]

  @type legacy_definition :: atom()
  @type target_definition :: keyword() | legacy_definition()

  typedstruct enforce: true do
    field :alias, atom()
    field :cpu, atom()
    field :os, atom()
    field :cross_build, boolean
    field :qualifiers, keyword()
    field :erts_source, erts_source()
    field :debug?, boolean()
  end

  @spec init_target(atom(), target_definition()) :: t()
  def init_target(_target_alias, legacy_definition) when is_atom(legacy_definition) do
    debug? = Mix.env() != :prod

    translated_target =
      case legacy_definition do
        :darwin -> [os: :darwin, cpu: :x86_64, debug?: debug?]
        :win64 -> [os: :windows, cpu: :x86_64, debug?: debug?]
        :linux -> [os: :linux, cpu: :x86_64, libc: :glibc, debug?: debug?]
        :linux_musl -> [os: :linux, cpu: :x86_64, libc: :musl, debug?: debug?]
        other -> raise "Unrecognized legacy build target: #{other}"
      end

    Log.warning(
      :build,
      "You have specified an old-style build target: #{legacy_definition}\n\tPlease see the Burrito README for instructions on migrating to the new format!"
    )

    init_target(legacy_definition, translated_target)
  end

  def init_target(target_alias, definition) do
    # pop off required options
    # then libc, and then custom erts definitions
    {fields, qualifiers} = Keyword.split(definition, [:os, :cpu, :debug?])
    {libc, qualifiers} = Keyword.pop(qualifiers, :libc)
    {custom_erts, qualifiers} = Keyword.pop(qualifiers, :custom_erts)

    if !fields[:os] || !fields[:cpu] do
      raise "You must define your target with AT LEAST `:os`, `:cpu` defined!"
    end

    # If linux, and no libc defined, default to the host system one
    libc =
      if fields[:os] == :linux do
        if libc == nil do
          # if we are not on a host that has a libc, default to glibc
          Util.get_libc_type() || :glibc
        else
          libc
        end
      end

    # translate the custom_erts (or lack of one) in a source to be resolved later
    cross_build = is_cross_build?(fields, libc)
    erts_source = translate_erts_source(custom_erts, cross_build)

    fields =
      fields
      |> Keyword.put(:alias, target_alias)
      |> Keyword.put(:qualifiers, [libc: libc] ++ qualifiers)
      |> Keyword.put(:erts_source, erts_source)
      |> Keyword.put(:debug?, fields[:debug?] || false)
      |> Keyword.put(:cross_build, is_cross_build?(fields, libc))

    struct!(__MODULE__, fields)
  end

  defp translate_erts_source(custom_location, cross_build?) do
    if custom_location do
      cond do
        is_uri?(custom_location) ->
          {:url, url: custom_location}

        String.ends_with?(custom_location, ".tar.gz") ->
          {:local, path: custom_location}

        File.dir?(custom_location) ->
          {:local_unpacked, path: custom_location}

        true ->
          raise "`:custom_erts` was not a URL, local path to tarball, or local path to a directory"
      end
    else
      if cross_build? do
        {:precompiled, version: Util.get_otp_version()}
      else
        {:runtime, []}
      end
    end
  end

  defp is_uri?(string) do
    case URI.parse(string) do
      %URI{scheme: nil} -> false
      %URI{host: nil, path: nil} -> false
      _ -> true
    end
  end

  defp is_cross_build?(fields, libc) do
    fields[:os] != Util.get_current_os() || fields[:cpu] != Util.get_current_cpu() ||
      libc != Util.get_libc_type()
  end

  @spec make_triplet(Burrito.Builder.Target.t()) :: String.t()
  def make_triplet(%Target{} = target) do
    os =
      case target.os do
        :darwin -> "macos"
        :windows -> "windows"
        :linux -> "linux"
      end

    triplet = "#{target.cpu}-#{os}"

    if target.qualifiers[:libc] do
      libc = translate_libc_to_zig(target.qualifiers[:libc])
      "#{triplet}-#{libc}"
    else
      triplet
    end
  end

  defp translate_libc_to_zig(:glibc), do: "gnu"
  defp translate_libc_to_zig(:musl), do: "musl"
  defp translate_libc_to_zig(abi), do: Atom.to_string(abi)

  @spec maybe_translate_old_target(atom()) :: keyword()
  def maybe_translate_old_target(old_target) when old_target in @old_targets do
    old_target =
      case old_target do
        :darwin -> [os: :darwin, cpu: :x86_64]
        :win64 -> [os: :windows, cpu: :x86_64]
        :linux -> [os: :linux, cpu: :x86_64, libc: :glibc]
        :linux_musl -> [os: :linux, cpu: :x86_64, libc: :musl]
      end

    Log.warning(
      :build,
      "You have specified an old-style build target, please move to using the newer format of build targets\n\t#{inspect(old_target)}\n\tSee the Burrito README for examples!"
    )

    old_target
  end

  def maybe_translate_old_target(not_old_target), do: not_old_target

  @spec get_old_targets :: [:darwin | :linux | :linux_musl | :win64]
  def get_old_targets do
    @old_targets
  end
end
