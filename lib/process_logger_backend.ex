defmodule ProcessLoggerBackend do
  @moduledoc """
  Documentation for ProcessLoggerBackend.
  """

  @behaviour :gen_event

  defmodule Config do
    @moduledoc """
    Configuration and internal state of the `LoggerBackend`.
    """

    @typedoc """
    A formatter to format the log msg before sending. It can be either a
    function or a tuple with a module and a function name.

    The functions receives the log msg, a timestamp as a erlang time tuple and
    the metadata as arguments and should return the formatted log msg.
    """
    @type formatter ::
            {module, atom}
            | (Logger.level(), String.t(), tuple, Logger.meta() -> any)

    @typedoc """
    Serves as internal state of the `ProcessLoggerBackend` and as config.

    * `level` - Specifies the log level.
    * `pid` - Specifies the process pid or name that receives the log messages.
    * `meta` - Additional metadata that will be added to the metadata before
      formatting.
    * `name` - The name of the lggger. This cannot be overridden.
    * `format` - A optional function that is used to format the log messages
      before sending. See `formatter()`.
    """
    @type t :: %__MODULE__{
            level: Logger.level(),
            pid: GenServer.name(),
            meta: Logger.metadata(),
            name: atom,
            format: nil | formatter
          }
    @enforce_keys [:name]
    defstruct level: :info, pid: nil, meta: [], name: nil, format: nil
  end

  def init({__MODULE__, name}) do
    {:ok, configure(name, [])}
  end

  def handle_call({:configure, opts}, %{name: name}) do
    {:ok, :ok, configure(name, opts)}
  end

  defp configure(name, opts) do
    applied_opts =
      :logger
      |> Application.get_env(name, [])
      |> Keyword.merge(opts)
      |> Keyword.put(:name, name)

    Application.put_env(:logger, name, applied_opts)

    struct!(Config, applied_opts)
  end

  def handle_event(:flush, state) do
    if process_alive?(state.pid) do
      send(state.pid, :flush)
    end

    {:ok, state}
  end

  def handle_event({_level, group_leader, _info}, state)
      when node(group_leader) != node() do
    {:ok, state}
  end

  def handle_event(_, %{pid: nil} = state) do
    {:ok, state}
  end

  def handle_event({level, _, {Logger, msg, timestamp, meta}}, state) do
    with true <- should_log?(state, level),
         true <- process_alive?(state.pid),
         meta <- Keyword.merge(meta, state.meta),
         {:ok, msg} <- format(state.format, [level, msg, timestamp, meta]) do
      send(state.pid, {level, msg, timestamp, meta})
    end

    {:ok, state}
  end

  defp should_log?(%{level: right}, left),
    do: :lt != Logger.compare_levels(left, right)

  defp process_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_alive?(name) when is_atom(name), do: Process.whereis(name) != nil

  defp format(nil, [_, msg, _, _]), do: {:ok, msg}
  defp format({mod, fun}, args), do: do_apply(mod, fun, args)
  defp format(fun, args), do: do_apply(fun, args)

  defp do_apply(fun, args) do
    {:ok, apply(fun, args)}
  rescue
    _ -> :error
  end

  defp do_apply(mod, fun, args) do
    {:ok, apply(mod, fun, args)}
  rescue
    _ -> :error
  end
end
