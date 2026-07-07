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

  it "raises a clear error when the underlying jj command fails" do
    allow(Jjt::Repo).to receive(:jj).and_call_original
    allow(Jjt::Repo).to receive(:jj).with("workspace", "add", "-r", "trunk()", anything,
                                           chdir: anything).and_raise(Jjt::Error, "boom")

    expect { pool.acquire }.to raise_error(Jjt::Error, "boom")
  end
end
