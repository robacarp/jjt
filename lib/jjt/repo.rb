# frozen_string_literal: true

require "open3"
require "pathname"

module Jjt
  # Finds the jj/git repo root above a directory, and runs `jj` against a
  # given repo/workspace path without needing to `Dir.chdir` into it.
  module Repo
    module_function

    def root(start_dir = Dir.pwd)
      dir = Pathname.new(File.expand_path(start_dir))

      loop do
        return dir.to_s if dir.join(".jj").directory? || dir.join(".git").exist?

        parent = dir.parent
        return nil if parent == dir

        dir = parent
      end
    end

    def root!(start_dir = Dir.pwd)
      root(start_dir) || raise(Jjt::Error, "no jj or git repository found above #{start_dir}")
    end

    def jj(*args, chdir:)
      stdout, stderr, status = Jjt::Trace.step("jj #{args.join(' ')}") do
        Open3.capture3("jj", "-R", chdir.to_s, *args)
      end
      raise Jjt::Error, "`jj #{args.join(' ')}` failed: #{stderr.strip}" unless status.success?

      stdout
    end
  end
end
