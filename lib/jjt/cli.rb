# frozen_string_literal: true

require "thor"

module Jjt
  class CLI < Thor
    default_task :get

    desc "get [NAME]", "Find an idle workspace, or create one, and spawn a subshell inside it"
    method_option :lease, type: :boolean, default: false, desc: "Reserve the workspace without spawning a subshell"
    method_option :lease_holder, type: :string, desc: "Label to record as the lease holder"
    def get(name = nil)
      with_error_handling do
        repo_root = resolve_repo_root
        entry = Jjt::Pool.new(repo_root: repo_root).acquire(name: name, lease: options[:lease],
                                                             lease_holder: options[:lease_holder])

        if options[:lease]
          puts entry.path
        else
          warn "jjt: workspace #{entry.name} ready at #{entry.path}"
          warn "jjt: run `jjt return` (or exit the shell) when you're done"
          ENV["JJT_REPO_ROOT"] = repo_root
          Dir.chdir(entry.path)
          Kernel.exec(ENV.fetch("SHELL", "/bin/sh"))
        end
      end
    end

    desc "status", "Show pool state and the current workspace's details"
    def status
      with_error_handling do
        pool = Jjt::Pool.new(repo_root: resolve_repo_root)
        entries = pool.list

        if entries.empty?
          puts "No workspaces yet for this repo. Run `jjt get` to create one."
        else
          entries.each do |e|
            holder = e.lease_holder ? " (#{e.lease_holder})" : ""
            puts "#{e.name}\t#{e.status}#{holder}\t#{e.path}"
          end
        end

        current = pool.find_by_path(Dir.pwd)
        puts "\nCurrent workspace: #{current.name} (#{current.status})" if current
      end
    end

    desc "return [PATH]", "Release a lease and return a workspace to the idle pool"
    def return(path = nil)
      with_error_handling do
        entry = Jjt::Pool.new.release(path || Dir.pwd)
        puts "jjt: released #{entry.name} back to the idle pool"
      end
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
      with_error_handling do
        path = File.join(resolve_repo_root, "jjt.toml")
        raise Jjt::Error, "#{path} already exists" if File.exist?(path)

        File.write(path, <<~TOML)
          max_trees = #{Jjt::Config::DEFAULT_MAX_TREES}
        TOML

        puts "jjt: wrote #{path}"
      end
    end

    desc "update", "Self-update jjt"
    def update
      raise NotImplementedError
    end

    desc "version", "Print the jjt version"
    def version
      puts Jjt::VERSION
    end

    no_commands do
      def with_error_handling
        yield
      rescue Jjt::Error => e
        warn "jjt: #{e.message}"
        exit 1
      end

      def resolve_repo_root
        ENV["JJT_REPO_ROOT"] || Jjt::Repo.root!
      end
    end
  end
end
