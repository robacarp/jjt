# frozen_string_literal: true

module Jjt
  # Opt-in timing trace (set JJT_DEBUG=1) for the steps `jjt get` runs before
  # it can spawn a shell — store lock waits, `jj` invocations, and hooks —
  # so a slow acquisition can be pinned to a specific step instead of just
  # "jjt is slow".
  module Trace
    module_function

    def enabled?
      !ENV["JJT_DEBUG"].to_s.empty?
    end

    def step(label)
      return yield unless enabled?

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        yield
      ensure
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        warn format("jjt: [debug] %s: %.2fs", label, elapsed)
      end
    end
  end
end
