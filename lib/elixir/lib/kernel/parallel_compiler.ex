defmodule Kernel.ParallelCompiler do
  alias Erlang.orddict, as: Orddict

  @moduledoc """
  A module responsible for compiling files in parallel.
  """

  defmacrop default_callback, do: quote(do: fn x -> x end)

  @doc """
  Compiles the given files.

  Those files are compiled in parallel and can automatically
  detect dependencies between them. Once a dependency is found,
  the current file stops being compiled until the dependency is
  resolved.

  A callback that is invoked every time a file is compiled
  with its name can be optionally given as argument.
  """
  def files(files, callback // default_callback) do
    files_to_path(files, nil, callback)
  end

  @doc """
  Compiles the given files to the given path.
  Read files/2 for more information.
  """
  def files_to_path(files, path, callback // default_callback) when is_binary(path) do
    Code.ensure_loaded(Kernel.ErrorHandler)
    spawn_compilers(files, path, callback, [], [], [])
  end

  # We already have 4 currently running, don't spawn new ones
  defp spawn_compilers(files, output, callback, waiting, queued, result) when
      length(queued) - length(waiting) >= 4 do
    wait_for_messages(files, output, callback, waiting, queued, result)
  end

  # Spawn a compiler for each file in the list until we reach the limit
  defp spawn_compilers([h|t], output, callback, waiting, queued, result) do
    parent = self()

    child  = spawn_link fn ->
      Process.put(:elixir_compiler_pid, parent)
      Process.put(:elixir_ensure_compiled, true)
      Process.flag(:error_handler, Kernel.ErrorHandler)

      try do
        if output do
          Erlang.elixir_compiler.file_to_path(h, output)
        else
          Erlang.elixir_compiler.file(h)
        end
        parent <- { :compiled, self(), h }
      catch
        kind, reason ->
          parent <- { :failure, self(), kind, reason, System.stacktrace }
      end
    end

    spawn_compilers(t, output, callback, waiting, [{child,h}|queued], result)
  end

  # No more files, nothing waiting, queue is empty, we are done
  defp spawn_compilers([], _output, _callback, [], [], result), do: result

  # Queued x, waiting for x: POSSIBLE ERROR! Release processes so we get the failures
  defp spawn_compilers([], output, callback, waiting, queued, result) when length(waiting) == length(queued) do
    Enum.each queued, fn { child, _ } -> child <- { :release, self() } end
    wait_for_messages([], output, callback, waiting, queued, result)
  end

  # No more files, but queue and waiting are not full or do not match
  defp spawn_compilers([], output, callback, waiting, queued, result) do
    wait_for_messages([], output, callback, waiting, queued, result)
  end

  # Wait for messages from child processes
  defp wait_for_messages(files, output, callback, waiting, queued, result) do
    receive do
      { :compiled, child, file } ->
        callback.(file)
        new_queued  = List.keydelete(queued, child, 0)
        # Sometimes we may have spurious entries in the waiting
        # list because someone invoked try/rescue UndefinedFunctionError
        new_waiting = List.keydelete(waiting, child, 0)
        spawn_compilers(files, output, callback, new_waiting, new_queued, result)
      { :module_available, child, module, binary } ->
        new_waiting = release_waiting_processes(module, waiting)
        new_result  = [{module, binary}|result]
        wait_for_messages(files, output, callback, new_waiting, queued, new_result)
      { :waiting, child, on } ->
        new_waiting = Orddict.store(child, on, waiting)
        spawn_compilers(files, output, callback, new_waiting, queued, result)
      { :failure, child, kind, reason, stacktrace } ->
        extra = if match?({^child, module}, List.keyfind(waiting, child, 0)) do
          " (undefined module #{inspect module})"
        end

      {^child, file} = List.keyfind(queued, child, 0)
      IO.puts "== Compilation error on file #{file}#{extra} =="
      Erlang.erlang.raise(kind, reason, stacktrace)
    end
  end

  # Release waiting processes that are waiting for the given module
  defp release_waiting_processes(module, waiting) do
    Enum.filter waiting, fn { child, waiting_module } ->
      if waiting_module == module do
        child <- { :release, self() }
        false
      else
        true
      end
    end
  end
end