#!/usr/bin/env elixir

root = Path.expand("..", __DIR__)
lib_root = Path.join(root, "lib")

repo_scoped_methods =
  ~w[
    delete_ci_check
    delete_pr_review
    delete_retry
    delete_verification_allocation
    interrupt_running_runs
    list_ci_checks
    list_eval_logs
    list_learnings
    list_pr_reviews
    list_retries
    list_runs
    list_verification_allocations
    update_ci_check
    update_pr_review
    update_run
    update_verification_allocation
  ]

default_scoped_patterns = [
  ~r/RunStore\.list_runs\(\s*(?:\)|:all|\d)/,
  ~r/RunStore\.list_retries\(\s*\)/,
  ~r/RunStore\.list_pr_reviews\(\s*\)/,
  ~r/RunStore\.list_ci_checks\(\s*\)/,
  ~r/RunStore\.list_verification_allocations\(\s*\)/,
  ~r/RunStore\.list_eval_logs\(\s*(?:\)|\[|[a-z_]+:)/,
  ~r/RunStore\.list_learnings\(\s*(?:\)|\[|[a-z_]+:)/,
  ~r/RunStore\.(?:update_run|update_pr_review|update_ci_check|update_verification_allocation)\(\s*[^,\)]+\s*,\s*%/,
  ~r/RunStore\.(?:delete_retry|delete_pr_review|delete_ci_check|delete_verification_allocation)\(\s*[^,\)]+\s*\)/,
  ~r/RunStore\.interrupt_running_runs\(\s*[^,\)]+\s*\)/
]

files =
  lib_root
  |> Path.join("**/*.ex")
  |> Path.wildcard()
  |> Enum.reject(&String.ends_with?(&1, "run_store.ex"))

call_sites =
  files
  |> Enum.flat_map(fn file ->
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      with [_match, method] <- Regex.run(~r/RunStore\.(\w+)/, line),
           true <- method in repo_scoped_methods do
        [{file, line_no, method, String.trim(line)}]
      else
        _ -> []
      end
    end)
  end)

suspect_sites =
  call_sites
  |> Enum.filter(fn {_file, _line_no, _method, line} ->
    String.starts_with?(line, "|>") == false and Enum.any?(default_scoped_patterns, &Regex.match?(&1, line))
  end)

Enum.each(call_sites, fn {file, line_no, method, line} ->
  path = Path.relative_to(file, root)
  IO.puts("#{path}:#{line_no} #{method} #{line}")
end)

if suspect_sites == [] do
  IO.puts("run-store repo_key audit: no obvious production default-scope call sites found")
else
  IO.puts(:stderr, "run-store repo_key audit failed: default-scope production call sites found")

  Enum.each(suspect_sites, fn {file, line_no, _method, line} ->
    path = Path.relative_to(file, root)
    IO.puts(:stderr, "#{path}:#{line_no} #{line}")
  end)

  System.halt(1)
end
