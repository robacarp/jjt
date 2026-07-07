# frozen_string_literal: true

require "tmpdir"

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
end
