# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"

module Jjt
  # Manages the pool of jj workspaces for one repo. State is kept in a single
  # global store (keyed by absolute workspace path) so that `jjt` commands
  # run from inside a workspace can find their entry without needing to
  # rediscover the original repo root, which isn't an ancestor directory of
  # a workspace created by `jj workspace add`.
  class Pool
    Entry = Struct.new(:name, :repo_root, :path, :status, :lease_holder, keyword_init: true)

    DEFAULT_STATE_DIR = File.join(ENV.fetch("XDG_STATE_HOME") { File.join(Dir.home, ".local", "state") }, "jjt")
    DEFAULT_STATE_PATH = File.join(DEFAULT_STATE_DIR, "state.json")

    def initialize(repo_root: Jjt::Repo.root!, config: Jjt::Config.load(start_dir: repo_root),
                    store: Jjt::Store.new(DEFAULT_STATE_PATH))
      @repo_root = File.expand_path(repo_root)
      @config = config
      @store = store
    end

    def list
      repo_workspaces(@store.read).map { |name, attrs| build_entry(name, attrs) }
    end

    def find_by_path(path)
      path = File.expand_path(path)
      entry = all_workspaces(@store.read).find { |_, attrs| File.expand_path(attrs["path"]) == path }
      entry && build_entry(*entry)
    end

    def acquire(name: nil, lease: false, lease_holder: nil)
      chosen = nil

      freshly_created = false

      @store.transaction do |data|
        workspaces = (data["workspaces"] ||= {})
        mine = workspaces.select { |_, attrs| attrs["repo_root"] == @repo_root }

        chosen_name, attrs, freshly_created = pick_workspace(workspaces, mine, name)

        attrs["status"] = lease ? "leased" : "in_use"
        if lease_holder
          attrs["lease_holder"] = lease_holder
        else
          attrs.delete("lease_holder")
        end

        chosen = build_entry(chosen_name, attrs)
        data
      end

      # A freshly created workspace is already anchored to trunk() via
      # `jj workspace add -r trunk()`; only a reused idle one needs resetting.
      reset_to_trunk(chosen.path) unless freshly_created
      chosen
    end

    def release(path)
      path = File.expand_path(path)
      released = nil

      @store.transaction do |data|
        workspaces = (data["workspaces"] ||= {})
        name, attrs = workspaces.find { |_, a| File.expand_path(a["path"]) == path }
        raise Jjt::Error, "#{path} is not a known jjt workspace" unless attrs

        attrs["status"] = "idle"
        attrs.delete("lease_holder")
        released = build_entry(name, attrs)
        data
      end

      released
    end

    private

    def pick_workspace(workspaces, mine, name)
      idle = mine.find { |_, attrs| attrs["status"] == "idle" }

      if name.nil? && idle
        return [*idle, false]
      elsif name && workspaces[name]
        entry = workspaces[name]
        unless entry["repo_root"] == @repo_root && entry["status"] == "idle"
          raise Jjt::Error, "workspace '#{name}' is not an idle workspace of this repo"
        end

        return [name, entry, false]
      elsif mine.size >= @config.max_trees
        raise Jjt::Error, "pool is full (max_trees=#{@config.max_trees}) and no idle workspace is available"
      end

      create_new_workspace(workspaces, name)
    end

    def create_new_workspace(workspaces, name)
      chosen_name = name || generate_name(workspaces)
      path = File.join(workspace_root, chosen_name)
      FileUtils.mkdir_p(workspace_root)
      Jjt::Repo.jj("workspace", "add", "-r", "trunk()", path, chdir: @repo_root)

      attrs = { "repo_root" => @repo_root, "path" => path, "status" => "idle" }
      workspaces[chosen_name] = attrs
      [chosen_name, attrs, true]
    end

    def workspace_root
      @config.root ? File.expand_path(@config.root) : File.join(DEFAULT_STATE_DIR, "workspaces", repo_id)
    end

    def repo_id
      Digest::SHA256.hexdigest(@repo_root)[0, 8]
    end

    def all_workspaces(data)
      data.fetch("workspaces", {})
    end

    def repo_workspaces(data)
      all_workspaces(data).select { |_, attrs| attrs["repo_root"] == @repo_root }
    end

    def build_entry(name, attrs)
      Entry.new(name: name, repo_root: attrs["repo_root"], path: attrs["path"], status: attrs["status"],
                 lease_holder: attrs["lease_holder"])
    end

    def generate_name(existing)
      loop do
        candidate = "ws-#{SecureRandom.hex(4)}"
        return candidate unless existing.key?(candidate)
      end
    end

    def reset_to_trunk(path)
      Jjt::Repo.jj("new", "trunk()", chdir: path)
    end
  end
end
