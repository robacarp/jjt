# frozen_string_literal: true

require "thor"

module Jjt
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    # Without this, Thor doesn't recognize `--version`/`-v` as the `version`
    # command — it falls through to `default_task :get` instead, which
    # creates a workspace literally named "--version".
    map %w[--version -v] => :version

    default_task :get

    desc "get [NAME]", "Find an idle workspace, or create one, and spawn a subshell inside it"
    method_option :lease, type: :boolean, default: false, desc: "Reserve the workspace without spawning a subshell"
    method_option :lease_holder, type: :string, desc: "Label to record as the lease holder"
    def get(name = nil)
      with_error_handling do
        repo_root = Jjt::Trace.step("resolve repo root") { resolve_repo_root }
        pool = Jjt::Pool.new(repo_root: repo_root)
        current = pool.find_by_path(Dir.pwd) if name.nil?

        if current
          if options[:lease]
            puts current.path
          else
            warn "jjt: already inside workspace #{current.name} (#{current.status}) at #{current.path}"
            exit(spawn_subshell_here(repo_root))
          end
          next
        end

        entry = Jjt::Trace.step("pool acquire") do
          pool.acquire(name: name, lease: options[:lease], lease_holder: options[:lease_holder])
        end

        if options[:lease]
          puts entry.path
        else
          warn "jjt: workspace #{entry.name} ready at #{entry.path}"
          warn "jjt: run `jjt return`, or just exit the shell, when you're done"
          exit(spawn_subshell(pool, entry, repo_root))
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
      with_error_handling do
        pool = Jjt::Pool.new(repo_root: resolve_repo_root)
        all = options[:all]
        candidates = pool.prune_candidates(
          global: options[:global],
          include_unlanded: all || options[:include_unlanded],
          include_in_use: all || options[:include_in_use],
          include_leased: all || options[:include_leased],
          prune_orphans: all || options[:prune_orphans]
        )

        if candidates.empty?
          puts "jjt: nothing to prune"
          next
        end

        verb = options[:yes] ? "removed" : "would remove"
        candidates.each do |c|
          pool.remove(c.entry) if options[:yes]
          line = "jjt: #{verb} #{c.entry.name}#{candidate_flags(c)}"
          line += " (#{c.entry.repo_root})" if options[:verbose]
          line += "\t#{c.entry.path}"
          puts line
        end

        puts "jjt: #{candidates.size} workspace(s) would be removed (pass --yes to actually remove)" unless options[:yes]
      end
    end

    desc "destroy PATH", "Remove a specific workspace"
    method_option :force, type: :boolean, default: false, desc: "Skip safety checks"
    def destroy(path)
      with_error_handling do
        pool = Jjt::Pool.new
        entry = pool.find_by_path(path)
        raise Jjt::Error, "#{path} is not a known jjt workspace" unless entry

        unless options[:force]
          unless entry.status == "idle"
            raise Jjt::Error, "workspace #{entry.name} is #{entry.status}; pass --force to remove it anyway"
          end

          unless Dir.exist?(entry.path)
            raise Jjt::Error,
                  "#{entry.path} no longer exists; pass --force to drop #{entry.name} anyway, " \
                  "or use `jjt prune --prune-orphans`"
          end

          if pool.unlanded_work?(entry.path)
            raise Jjt::Error, "workspace #{entry.name} has unlanded work; pass --force to remove it anyway"
          end
        end

        pool.remove(entry)
        puts "jjt: removed #{entry.name}"
      end
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
        ENV["JJT_REPO_ROOT"] || Jjt::Pool.repo_root_for(Dir.pwd) || Jjt::Repo.root!
      end

      def candidate_flags(candidate)
        flags = []
        flags << "orphan" if candidate.orphan
        flags << candidate.entry.status if candidate.entry.status != "idle"
        flags << "unlanded work" if candidate.unlanded
        flags.empty? ? "" : " (#{flags.join(', ')})"
      end

      # A real subshell (not `exec`) so we can auto-release once it exits.
      # SIGINT is ignored here while it runs so Ctrl-C reaches the subshell
      # instead of killing jjt before the release below.
      def spawn_subshell(pool, entry, repo_root)
        prev_trap = Signal.trap("INT", "IGNORE")
        system({ "JJT_REPO_ROOT" => repo_root }, ENV.fetch("SHELL", "/bin/sh"), chdir: entry.path)
        $?.exitstatus || 1
      ensure
        Signal.trap("INT", prev_trap) if prev_trap
        auto_release(pool, entry)
      end

      # For a shell that's already sitting inside a known workspace (cwd is
      # the workspace root or a subdirectory of it): spawns a subshell in
      # place, without touching pool state. This invocation didn't lease the
      # workspace, so it doesn't auto-release it on exit either — another
      # shell may still be actively using it.
      def spawn_subshell_here(repo_root)
        prev_trap = Signal.trap("INT", "IGNORE")
        system({ "JJT_REPO_ROOT" => repo_root }, ENV.fetch("SHELL", "/bin/sh"))
        $?.exitstatus || 1
      ensure
        Signal.trap("INT", prev_trap) if prev_trap
      end

      def auto_release(pool, entry)
        current = pool.find_by_path(entry.path)
        return unless current && current.status != "idle"

        pool.release(entry.path)
        warn "jjt: released #{entry.name} back to the idle pool"
      rescue Jjt::Error => e
        warn "jjt: failed to auto-release #{entry.name}: #{e.message}"
      end
    end
  end
end
