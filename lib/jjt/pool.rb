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
    Candidate = Struct.new(:entry, :orphan, :unlanded, keyword_init: true)

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

        if freshly_created
          # Reserve the slot now, but leave the actual `jj workspace add` to run
          # below, outside this lock — otherwise one repo's checkout stalls
          # every other repo's `jjt get`, since the store is a single global file.
          attrs["status"] = "creating"
        else
          attrs["status"] = lease ? "leased" : "in_use"
          if lease_holder
            attrs["lease_holder"] = lease_holder
          else
            attrs.delete("lease_holder")
          end
        end

        chosen = build_entry(chosen_name, attrs)
        data
      end

      if freshly_created
        begin
          create_workspace_on_disk(chosen.path)
        rescue StandardError
          drop_reservation(chosen.name)
          raise
        end

        chosen = finalize_created_workspace(chosen.name, lease: lease, lease_holder: lease_holder)
      else
        # A freshly created workspace is already anchored to trunk() via
        # `jj workspace add -r trunk()`; only a reused idle one needs resetting.
        reset_to_trunk(chosen.path)
      end

      run_hooks(:post_create, chosen.path)
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

    # True if the workspace has real (non-empty) commits that aren't yet an
    # ancestor of trunk() — i.e. work that would be lost if it were removed.
    # This also covers the "clean" half of prune's safety check: an idle
    # workspace with an in-progress edit just shows up as its own non-empty
    # commit here, since @ is included in `::@`.
    def unlanded_work?(path)
      output = Jjt::Repo.jj("log", "-r", "(::@ ~ ::trunk()) ~ empty()", "--no-graph", "-T", 'commit_id ++ "\n"',
                             chdir: path)
      !output.strip.empty?
    end

    # Candidates for `prune`. Default scope is idle workspaces of this repo
    # with no unlanded work; the include_* flags widen that one dimension at
    # a time, and prune_orphans adds a separate class of entry (state-store
    # rows whose workspace directory is simply gone).
    def prune_candidates(global: false, include_unlanded: false, include_in_use: false, include_leased: false,
                          prune_orphans: false)
      scope = global ? all_workspaces(@store.read) : repo_workspaces(@store.read)

      scope.filter_map do |name, attrs|
        entry = build_entry(name, attrs)
        next if entry.status == "creating"

        unless Dir.exist?(entry.path)
          next Candidate.new(entry: entry, orphan: true, unlanded: false) if prune_orphans

          next
        end

        next if entry.status == "leased" && !include_leased
        next if entry.status == "in_use" && !include_in_use

        unlanded = unlanded_work?(entry.path)
        next if unlanded && !include_unlanded

        Candidate.new(entry: entry, orphan: false, unlanded: unlanded)
      end
    end

    # Removes a workspace: runs the pre_destroy hook (if the directory is
    # still there), forgets it from jj's own workspace list, deletes the
    # directory, then drops its row from the store.
    def remove(entry)
      if Dir.exist?(entry.path)
        # A global prune can remove another repo's workspace, whose
        # pre_destroy hook (if any) lives in *that* repo's jjt.toml, not ours.
        config = entry.repo_root == @repo_root ? @config : Jjt::Config.load(start_dir: entry.repo_root)
        run_hooks(:pre_destroy, entry.path, repo_root: entry.repo_root, config: config)
        forget_workspace(entry)
        FileUtils.rm_rf(entry.path)
      else
        forget_workspace(entry)
      end

      @store.transaction do |data|
        data.fetch("workspaces", {}).delete(entry.name)
        data
      end

      nil
    end

    private

    def forget_workspace(entry)
      Jjt::Repo.jj("workspace", "forget", entry.name, chdir: entry.repo_root)
    rescue Jjt::Error
      # Already forgotten, or the source repo is gone — the store row still
      # needs to be dropped either way, so don't let this block that.
      nil
    end

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

      attrs = { "repo_root" => @repo_root, "path" => path }
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

    def create_workspace_on_disk(path)
      FileUtils.mkdir_p(workspace_root)
      Jjt::Repo.jj("workspace", "add", "-r", "trunk()", path, chdir: @repo_root)
    end

    def finalize_created_workspace(name, lease:, lease_holder:)
      entry = nil

      @store.transaction do |data|
        attrs = data.fetch("workspaces").fetch(name)
        attrs["status"] = lease ? "leased" : "in_use"
        if lease_holder
          attrs["lease_holder"] = lease_holder
        else
          attrs.delete("lease_holder")
        end

        entry = build_entry(name, attrs)
        data
      end

      entry
    end

    def drop_reservation(name)
      @store.transaction do |data|
        data.fetch("workspaces", {}).delete(name)
        data
      end
    end

    # Each hook command runs sequentially via the OS shell, in the workspace
    # directory, with JJT_REPO_ROOT set so it can pull from the source repo.
    # A failing command is logged, not raised: one broken hook shouldn't strand
    # the caller without a workspace.
    def run_hooks(name, path, repo_root: @repo_root, config: @config)
      Array(config.hooks[name]).each do |command|
        system({ "JJT_REPO_ROOT" => repo_root }, command, chdir: path)
        warn "jjt: #{name} hook failed (#{command.inspect})" unless $?.success?
      end
    end
  end
end
