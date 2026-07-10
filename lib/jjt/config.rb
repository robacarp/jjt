# frozen_string_literal: true

require "tomlib"

module Jjt
  class Config
    DEFAULT_MAX_TREES = 16
    USER_CONFIG_PATH = File.expand_path("~/.config/jjt/config.toml")

    attr_reader :max_trees, :root, :hooks

    class << self
      def load(start_dir: Dir.pwd, user_config_path: USER_CONFIG_PATH)
        user_data = read_toml(user_config_path)
        repo_data = read_toml(repo_config_path(start_dir))
        repo_data.delete("hooks")

        new(deep_merge(user_data, repo_data))
      end

      private

      def repo_config_path(start_dir)
        root = Jjt::Repo.root(start_dir)
        return nil unless root

        candidate = File.join(root, "jjt.toml")
        candidate if File.file?(candidate)
      end

      def read_toml(path)
        return {} unless path && File.file?(path)

        Tomlib.load(File.read(path))
      rescue Tomlib::ParseError => e
        raise Jjt::Error, "Failed to parse #{path}: #{e.message}"
      end

      def deep_merge(base, overrides)
        base.merge(overrides) do |_key, base_val, override_val|
          if base_val.is_a?(Hash) && override_val.is_a?(Hash)
            deep_merge(base_val, override_val)
          else
            override_val
          end
        end
      end
    end

    def initialize(data)
      @max_trees = Integer(data.fetch("max_trees", DEFAULT_MAX_TREES))
      raise Jjt::Error, "max_trees must be a positive integer" unless @max_trees.positive?

      @root = data["root"]
      @hooks = (data["hooks"] || {}).transform_keys(&:to_sym)
    end
  end
end
