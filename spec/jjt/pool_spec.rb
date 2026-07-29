# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Jjt::Pool do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = Pathname.new(dir)
      example.run
    end
  end

  let(:repo_root) { "/repo/a" }
  let(:other_repo_root) { "/repo/b" }
  let(:config) { Jjt::Config.new("max_trees" => 2, "root" => @tmp.join("workspaces").to_s) }
  let(:store) { Jjt::Store.new(@tmp.join("state.json").to_s) }

  subject(:pool) { described_class.new(repo_root: repo_root, config: config, store: store) }

  def other_pool
    described_class.new(repo_root: other_repo_root, config: config, store: store)
  end

  before do
    allow(Jjt::Repo).to receive(:jj)
  end

  it "creates a new workspace anchored to trunk() when none are idle" do
    entry = pool.acquire

    expect(entry.status).to eq("in_use")
    expect(entry.repo_root).to eq(repo_root)
    expect(Jjt::Repo).to have_received(:jj).with("workspace", "add", "-r", "trunk()", entry.path, chdir: repo_root)
    expect(Jjt::Repo).not_to have_received(:jj).with("new", "trunk()", chdir: anything)
  end

  it "reuses an idle workspace instead of creating a new one" do
    first = pool.acquire
    pool.release(first.path)

    second = pool.acquire

    expect(second.path).to eq(first.path)
    expect(second.status).to eq("in_use")
    expect(Jjt::Repo).to have_received(:jj).with("new", "trunk()", chdir: first.path)
    expect(Jjt::Repo).to have_received(:jj).with("workspace", "add", anything, anything, anything,
                                                  chdir: repo_root).once
  end

  it "records a lease holder when leasing instead of checking out in_use" do
    entry = pool.acquire(lease: true, lease_holder: "agent-1")

    expect(entry.status).to eq("leased")
    expect(entry.lease_holder).to eq("agent-1")
  end

  it "raises once the pool is full and nothing is idle" do
    pool.acquire
    pool.acquire

    expect { pool.acquire }.to raise_error(Jjt::Error, /pool is full/)
  end

  it "does not reuse an idle workspace belonging to a different repo" do
    borrowed = other_pool.acquire
    other_pool.release(borrowed.path)

    entry = pool.acquire

    expect(entry.path).not_to eq(borrowed.path)
    expect(entry.repo_root).to eq(repo_root)
  end

  it "raises when releasing a path that isn't a known workspace" do
    expect { pool.release("/nope") }.to raise_error(Jjt::Error, /not a known jjt workspace/)
  end

  it "lists only this repo's workspaces" do
    other_pool.acquire
    mine = pool.acquire

    expect(pool.list.map(&:path)).to eq([mine.path])
  end

  it "finds a workspace by path regardless of which repo's pool looks it up" do
    borrowed = other_pool.acquire

    found = pool.find_by_path(borrowed.path)

    expect(found.repo_root).to eq(other_repo_root)
  end

  it "looks up a workspace's repo_root by path alone, with no bound pool instance" do
    entry = pool.acquire

    expect(described_class.repo_root_for(entry.path, store: store)).to eq(repo_root)
  end

  it "returns nil from repo_root_for when the path isn't a known workspace" do
    expect(described_class.repo_root_for("/nope", store: store)).to be_nil
  end

  it "reacquires a specific idle workspace by name" do
    entry = pool.acquire
    pool.release(entry.path)

    reacquired = pool.acquire(name: entry.name)

    expect(reacquired.path).to eq(entry.path)
  end

  it "raises when the named workspace is not idle" do
    entry = pool.acquire

    expect { pool.acquire(name: entry.name) }.to raise_error(Jjt::Error, /not an idle workspace/)
  end

  it "does not block another repo's acquire while a workspace is being checked out" do
    entered_jj = Queue.new
    release_jj = Queue.new

    allow(Jjt::Repo).to receive(:jj) do |*args, **kwargs|
      if args.first == "workspace" && kwargs[:chdir] == repo_root
        entered_jj << :entered
        release_jj.pop
      end
    end

    creating = Thread.new { pool.acquire }
    entered_jj.pop # wait until `creating` is inside the (blocked) `jj workspace add` call

    other_entry = nil
    other_thread = Thread.new { other_entry = other_pool.acquire }
    finished = other_thread.join(2)

    release_jj << :go
    creating.join(2)

    expect(finished).not_to be_nil
    expect(other_entry.repo_root).to eq(other_repo_root)
  end

  it "drops the reservation if `jj workspace add` fails" do
    allow(Jjt::Repo).to receive(:jj).and_raise(Jjt::Error, "boom")

    expect { pool.acquire }.to raise_error(Jjt::Error, "boom")
    expect(pool.list).to be_empty
  end

  describe "#prune_candidates" do
    before { allow(Jjt::Repo).to receive(:jj).and_return("") }

    def stub_unlanded(path, unlanded:)
      allow(Jjt::Repo).to receive(:jj) do |*args, **kwargs|
        args.first == "log" && kwargs[:chdir] == path ? (unlanded ? "abc123\n" : "") : ""
      end
    end

    it "returns idle workspaces of this repo with no unlanded work by default" do
      entry = pool.acquire
      FileUtils.mkdir_p(entry.path)
      pool.release(entry.path)

      candidates = pool.prune_candidates

      expect(candidates.map { |c| c.entry.path }).to eq([entry.path])
      expect(candidates.first.orphan).to be(false)
      expect(candidates.first.unlanded).to be(false)
    end

    it "excludes in_use and leased workspaces by default, including them only when asked" do
      in_use = pool.acquire
      FileUtils.mkdir_p(in_use.path)
      leased = pool.acquire(lease: true)
      FileUtils.mkdir_p(leased.path)

      expect(pool.prune_candidates).to be_empty

      widened = pool.prune_candidates(include_in_use: true, include_leased: true)
      expect(widened.map { |c| c.entry.path }).to contain_exactly(in_use.path, leased.path)
    end

    it "excludes workspaces with unlanded work unless asked" do
      entry = pool.acquire
      FileUtils.mkdir_p(entry.path)
      pool.release(entry.path)
      stub_unlanded(entry.path, unlanded: true)

      expect(pool.prune_candidates).to be_empty

      widened = pool.prune_candidates(include_unlanded: true)
      expect(widened.map { |c| c.entry.path }).to eq([entry.path])
      expect(widened.first.unlanded).to be(true)
    end

    it "flags entries whose workspace directory is gone as orphans, only when asked" do
      entry = pool.acquire
      pool.release(entry.path) # note: no FileUtils.mkdir_p — directory never existed

      expect(pool.prune_candidates).to be_empty

      widened = pool.prune_candidates(prune_orphans: true)
      expect(widened.map { |c| c.entry.path }).to eq([entry.path])
      expect(widened.first.orphan).to be(true)
    end

    it "never surfaces a workspace that is still mid-creation" do
      store.transaction do |data|
        data["workspaces"] = { "ws-x" => { "repo_root" => repo_root, "path" => "/nope", "status" => "creating" } }
        data
      end

      expect(pool.prune_candidates(prune_orphans: true)).to be_empty
    end

    it "scopes to this repo unless global is set" do
      theirs = other_pool.acquire
      FileUtils.mkdir_p(theirs.path)
      other_pool.release(theirs.path)

      mine = pool.acquire
      FileUtils.mkdir_p(mine.path)
      pool.release(mine.path)

      expect(pool.prune_candidates.map { |c| c.entry.path }).to eq([mine.path])

      global = pool.prune_candidates(global: true)
      expect(global.map { |c| c.entry.path }).to contain_exactly(mine.path, theirs.path)
    end
  end

  describe "#remove" do
    before { allow(Jjt::Repo).to receive(:jj).and_return("") }

    it "forgets the workspace, deletes its directory, and drops it from the store" do
      entry = pool.acquire
      FileUtils.mkdir_p(entry.path)

      pool.remove(entry)

      expect(Jjt::Repo).to have_received(:jj).with("workspace", "forget", entry.name, chdir: repo_root)
      expect(Dir.exist?(entry.path)).to be(false)
      expect(pool.find_by_path(entry.path)).to be_nil
    end

    it "still drops the store entry when the directory is already gone" do
      entry = pool.acquire
      pool.release(entry.path)

      pool.remove(entry)

      expect(pool.find_by_path(entry.path)).to be_nil
    end

    it "does not raise if `jj workspace forget` fails" do
      entry = pool.acquire
      FileUtils.mkdir_p(entry.path)
      allow(Jjt::Repo).to receive(:jj).with("workspace", "forget", anything, chdir: anything)
                                       .and_raise(Jjt::Error, "already forgotten")

      expect { pool.remove(entry) }.not_to raise_error
      expect(pool.find_by_path(entry.path)).to be_nil
    end

    it "loads the owning repo's config for a global removal, not the caller's" do
      theirs = other_pool.acquire
      FileUtils.mkdir_p(theirs.path)
      other_config = Jjt::Config.new("max_trees" => 2)

      expect(Jjt::Config).to receive(:load).with(start_dir: other_repo_root).and_return(other_config)

      pool.remove(theirs)
    end
  end
end
