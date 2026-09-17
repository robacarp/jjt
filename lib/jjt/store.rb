# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module Jjt
  # A JSON-backed key/value store with a file lock guarding every read and
  # write, so two `jjt` processes never observe or clobber a half-written
  # pool state. Writes go to a temp file in the same directory and are
  # `rename`d into place, so a reader never sees a partial write.
  class Store
    def initialize(path)
      @path = File.expand_path(path)
      @lock_path = "#{@path}.lock"
    end

    def read
      with_lock { read_unlocked }
    end

    def transaction
      raise ArgumentError, "block required" unless block_given?

      with_lock do
        data = yield read_unlocked
        write_unlocked(data)
        data
      end
    end

    private

    def with_lock
      FileUtils.mkdir_p(File.dirname(@path))

      File.open(@lock_path, File::CREAT | File::RDWR, 0o644) do |lock_file|
        Jjt::Trace.step("store lock wait") { lock_file.flock(File::LOCK_EX) }
        yield
      end
    end

    def read_unlocked
      return {} unless File.file?(@path)

      contents = File.read(@path)
      return {} if contents.strip.empty?

      JSON.parse(contents)
    rescue JSON::ParserError => e
      raise Jjt::Error, "Failed to parse state file #{@path}: #{e.message}"
    end

    def write_unlocked(data)
      dir = File.dirname(@path)
      tmp_path = File.join(dir, ".#{File.basename(@path)}.#{SecureRandom.hex(6)}.tmp")

      File.write(tmp_path, JSON.pretty_generate(data))
      File.rename(tmp_path, @path)
    ensure
      File.delete(tmp_path) if tmp_path && File.exist?(tmp_path)
    end
  end
end
