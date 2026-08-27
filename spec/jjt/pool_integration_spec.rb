# frozen_string_literal: true

require "tmpdir"
require "open3"

RSpec.describe Jjt::Pool, "against a real jj repo" do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = Pathname.new(dir)
      @repo_root = @tmp.join("repo").to_s
      Open3.capture2e("jj", "git", "init", @repo_root)
      Open3.capture2e("jj", "-R", @repo_root, "config", "set", "--repo", "user.name", "jjt-spec")
      Open3.capture2e("jj", "-R", @repo_root, "config", "set", "--repo", "user.email", "jjt-spec@example.com")
      File.write(File.join(@repo_root, "README.md"), "hello\n")
      Open3.capture2e("jj", "-R", @repo_root, "commit", "-m", "initial")
      example.run
    end
  end

  let(:config) { Jjt::Config.new("max_trees" => 2, "root" => @tmp.join("workspaces").to_s) }
  let(:store) { Jjt::Store.new(@tmp.join("state.json").to_s) }
  subject(:pool) { described_class.new(repo_root: @repo_root, config: config, store: store) }

  it "creates a real jj workspace on acquire and can release and reuse it" do
    entry = pool.acquire

    expect(File.directory?(entry.path)).to be(true)
    expect(File.directory?(File.join(entry.path, ".jj"))).to be(true)

    released = pool.release(entry.path)
    expect(released.status).to eq("idle")

    reused = pool.acquire
    expect(reused.path).to eq(entry.path)
    expect(reused.status).to eq("in_use")
  end

  it "recovers automatically when a reused workspace's working copy is stale" do
    stale = pool.acquire
    other = pool.acquire
    pool.release(stale.path)

    stale_commit = Open3.capture2("jj", "-R", stale.path, "log", "--no-graph", "-r", "@", "-T", "commit_id")
                         .first.strip

    # Same staleness trigger as the `#unlanded_work?` spec below, but this
    # time it's hit via `acquire`'s reset-to-trunk on a reused workspace,
    # which is what a plain `jjt get` runs through.
    _out, err, status = Open3.capture3("jj", "-R", other.path, "abandon", stale_commit)
    raise "test setup failed: #{err}" unless status.success?

    reused = pool.acquire

    expect(reused.path).to eq(stale.path)
    expect(reused.status).to eq("in_use")
  end

  it "raises a clear error when the underlying jj command fails" do
    allow(Jjt::Repo).to receive(:jj).and_call_original
    allow(Jjt::Repo).to receive(:jj).with("workspace", "add", "-r", "trunk()", anything,
                                           chdir: anything).and_raise(Jjt::Error, "boom")

    expect { pool.acquire }.to raise_error(Jjt::Error, "boom")
    expect(pool.list).to be_empty
  end

  context "with a post_create hook configured" do
    let(:config) do
      Jjt::Config.new(
        "max_trees" => 2,
        "root" => @tmp.join("workspaces").to_s,
        "hooks" => { "post_create" => 'echo "$JJT_REPO_ROOT" > repo_root_seen_by_hook.txt' }
      )
    end

    it "runs the hook in the new workspace with JJT_REPO_ROOT set" do
      entry = pool.acquire

      marker = File.join(entry.path, "repo_root_seen_by_hook.txt")
      expect(File.read(marker).strip).to eq(@repo_root)
    end

    it "runs the hook again after resetting a reused workspace" do
      entry = pool.acquire
      pool.release(entry.path)
      marker = File.join(entry.path, "repo_root_seen_by_hook.txt")
      File.delete(marker)

      pool.acquire

      expect(File.exist?(marker)).to be(true)
    end
  end

  describe "#unlanded_work?" do
    it "is false for a freshly created workspace" do
      entry = pool.acquire

      expect(pool.unlanded_work?(entry.path)).to be(false)
    end

    it "is true once real work is committed in the workspace" do
      entry = pool.acquire
      File.write(File.join(entry.path, "notes.txt"), "wip\n")
      Open3.capture2e("jj", "-R", entry.path, "describe", "-m", "wip")

      expect(pool.unlanded_work?(entry.path)).to be(true)
    end

    it "goes back to false once the workspace is released and reset to trunk" do
      entry = pool.acquire
      File.write(File.join(entry.path, "notes.txt"), "wip\n")
      Open3.capture2e("jj", "-R", entry.path, "describe", "-m", "wip")
      pool.release(entry.path)

      reused = pool.acquire

      expect(pool.unlanded_work?(reused.path)).to be(false)
    end

    it "recovers automatically when the workspace's working copy is stale" do
      stale = pool.acquire
      other = pool.acquire

      stale_commit = Open3.capture2("jj", "-R", stale.path, "log", "--no-graph", "-r", "@", "-T", "commit_id")
                           .first.strip

      # Abandoning a workspace's working-copy commit from a *different*
      # workspace is exactly what makes that workspace's on-disk checkout go
      # stale in jj — the same situation `jjt destroy`/`jj workspace forget`
      # on one pool workspace put every other workspace into.
      _out, err, status = Open3.capture3("jj", "-R", other.path, "abandon", stale_commit)
      raise "test setup failed: #{err}" unless status.success?

      expect(pool.unlanded_work?(stale.path)).to be(false)
    end
  end

  describe "#prune_candidates" do
    it "only surfaces workspaces without unlanded work by default" do
      # Acquired while `clean` is still in_use (not idle), so this is a
      # distinct workspace rather than a reuse of `clean`'s.
      clean = pool.acquire
      dirty = pool.acquire
      File.write(File.join(dirty.path, "notes.txt"), "wip\n")
      Open3.capture2e("jj", "-R", dirty.path, "describe", "-m", "wip")

      pool.release(clean.path)
      pool.release(dirty.path)

      expect(pool.prune_candidates.map { |c| c.entry.path }).to eq([clean.path])

      widened = pool.prune_candidates(include_unlanded: true).map { |c| c.entry.path }
      expect(widened).to contain_exactly(clean.path, dirty.path)
    end
  end

  describe "#remove" do
    it "forgets the jj workspace and deletes the directory" do
      entry = pool.acquire
      path = entry.path

      pool.remove(entry)

      expect(Dir.exist?(path)).to be(false)
      expect(pool.find_by_path(path)).to be_nil

      workspace_list = Open3.capture2("jj", "-R", @repo_root, "workspace", "list").first
      expect(workspace_list).not_to include(entry.name)
    end
  end

  context "with a pre_destroy hook configured" do
    let(:marker) { @tmp.join("pre_destroy_seen.txt") }
    let(:config) do
      Jjt::Config.new(
        "max_trees" => 2,
        "root" => @tmp.join("workspaces").to_s,
        "hooks" => { "pre_destroy" => %(echo "$JJT_REPO_ROOT" > "#{marker}") }
      )
    end

    it "runs the hook, in the workspace, before it's removed" do
      entry = pool.acquire

      pool.remove(entry)

      expect(File.read(marker).strip).to eq(@repo_root)
    end
  end
end
