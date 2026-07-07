# frozen_string_literal: true

require "thor"

module Jjt
  class CLI < Thor
    desc "get [PATH]", "Find an idle workspace, or create one, and spawn a subshell inside it"
    method_option :lease, type: :boolean, default: false, desc: "Reserve the workspace without spawning a subshell"
    method_option :lease_holder, type: :string, desc: "Label to record as the lease holder"
    def get(path = nil)
      raise NotImplementedError
    end

    desc "status", "Show pool state and the current workspace's details"
    def status
      raise NotImplementedError
    end

    desc "return [PATH]", "Release a lease and return a workspace to the idle pool"
    def return(path = nil)
      raise NotImplementedError
    end

    desc "prune", "Remove idle, clean, merged workspaces (dry-run unless --yes)"
    method_option :yes, type: :boolean, default: false, desc: "Actually remove workspaces instead of a dry run"
    method_option :all, type: :boolean, default: false
    method_option :global, type: :boolean, default: false
    method_option :verbose, type: :boolean, default: false
    method_option :include_unlanded, type: :boolean, default: false
    method_option :include_in_use, type: :boolean, default: false
    method_option :include_leased, type: :boolean, default: false
    method_option :prune_orphans, type: :boolean, default: false
    def prune
      raise NotImplementedError
    end

    desc "destroy PATH", "Remove a specific workspace"
    method_option :force, type: :boolean, default: false, desc: "Skip safety checks"
    def destroy(path)
      raise NotImplementedError
    end

    desc "init", "Write a default jjt.toml"
    def init
      raise NotImplementedError
    end

    desc "update", "Self-update jjt"
    def update
      raise NotImplementedError
    end

    desc "version", "Print the jjt version"
    def version
      raise NotImplementedError
    end
  end
end
