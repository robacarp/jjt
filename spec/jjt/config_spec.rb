# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Jjt::Config do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = Pathname.new(dir)
      example.run
    end
  end

  def repo(relative = ".", vcs: :jj)
    dir = @tmp.join(relative)
    FileUtils.mkdir_p(dir)
    FileUtils.mkdir_p(dir.join(vcs == :jj ? ".jj" : ".git"))
    dir
  end

  def write(path, contents)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  let(:missing_user_config) { @tmp.join("no-such-user-config.toml").to_s }

  it "falls back to defaults when no config files exist" do
    config = described_class.load(start_dir: repo.to_s, user_config_path: missing_user_config)

    expect(config.max_trees).to eq(16)
    expect(config.root).to be_nil
    expect(config.hooks).to eq({})
  end

  it "reads repo-level jjt.toml from the repo root" do
    dir = repo
    write(dir.join("jjt.toml"), "max_trees = 4\nroot = \"/tmp/trees\"\n")

    config = described_class.load(start_dir: dir.to_s, user_config_path: missing_user_config)

    expect(config.max_trees).to eq(4)
    expect(config.root).to eq("/tmp/trees")
  end

  it "finds the repo root by walking up from a nested directory" do
    dir = repo
    write(dir.join("jjt.toml"), "max_trees = 7\n")
    nested = dir.join("a/b/c")
    FileUtils.mkdir_p(nested)

    config = described_class.load(start_dir: nested.to_s, user_config_path: missing_user_config)

    expect(config.max_trees).to eq(7)
  end

  it "detects a colocated git repo root when there is no .jj directory" do
    dir = repo(vcs: :git)
    write(dir.join("jjt.toml"), "max_trees = 9\n")

    config = described_class.load(start_dir: dir.to_s, user_config_path: missing_user_config)

    expect(config.max_trees).to eq(9)
  end

  it "layers user config under repo config, with repo config winning on conflicts" do
    user_config = @tmp.join("user-config.toml")
    write(user_config, "max_trees = 2\n")

    dir = repo
    write(dir.join("jjt.toml"), "max_trees = 5\n")

    config = described_class.load(start_dir: dir.to_s, user_config_path: user_config.to_s)

    expect(config.max_trees).to eq(5)
  end

  it "only honors hooks from user config, ignoring any set in repo-level jjt.toml" do
    user_config = @tmp.join("user-config.toml")
    write(user_config, <<~TOML)
      [hooks]
      post_create = "user post_create"
      pre_destroy = "user pre_destroy"
    TOML

    dir = repo
    write(dir.join("jjt.toml"), <<~TOML)
      [hooks]
      post_create = "repo post_create"
    TOML

    config = described_class.load(start_dir: dir.to_s, user_config_path: user_config.to_s)

    expect(config.hooks).to eq(post_create: "user post_create", pre_destroy: "user pre_destroy")
  end

  it "raises when max_trees is not a positive integer" do
    dir = repo
    write(dir.join("jjt.toml"), "max_trees = 0\n")

    expect do
      described_class.load(start_dir: dir.to_s, user_config_path: missing_user_config)
    end.to raise_error(Jjt::Error, /positive integer/)
  end

  it "raises a Jjt::Error when a config file has invalid TOML" do
    dir = repo
    write(dir.join("jjt.toml"), "this is not [ valid toml")

    expect do
      described_class.load(start_dir: dir.to_s, user_config_path: missing_user_config)
    end.to raise_error(Jjt::Error, /Failed to parse/)
  end
end
