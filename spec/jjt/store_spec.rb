# frozen_string_literal: true

require "tmpdir"

RSpec.describe Jjt::Store do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "state.json")
      example.run
    end
  end

  subject(:store) { described_class.new(@path) }

  it "reads an empty hash when the state file does not exist" do
    expect(store.read).to eq({})
  end

  it "persists whatever a transaction returns" do
    store.transaction { |data| data.merge("workspaces" => ["a"]) }

    expect(store.read).to eq("workspaces" => ["a"])
  end

  it "hands the transaction block the current data for read-modify-write" do
    store.transaction { |data| data.merge("count" => 1) }

    result = store.transaction { |data| data.merge("count" => data.fetch("count") + 1) }

    expect(result).to eq("count" => 2)
    expect(store.read).to eq("count" => 2)
  end

  it "raises a Jjt::Error when the state file contains invalid JSON" do
    File.write(@path, "not json")

    expect { store.read }.to raise_error(Jjt::Error, /Failed to parse/)
  end

  it "leaves no temp files behind after a transaction" do
    store.transaction { |data| data.merge("a" => 1) }

    leftovers = Dir.glob(File.join(File.dirname(@path), ".*.tmp"))
    expect(leftovers).to be_empty
  end

  it "serializes transactions across separate Store instances via the file lock" do
    order = Queue.new
    a_holding_lock = Queue.new

    thread_a = Thread.new do
      described_class.new(@path).transaction do |data|
        order << :a_start
        a_holding_lock << true
        sleep 0.2
        order << :a_end
        data.merge("a" => true)
      end
    end

    a_holding_lock.pop

    thread_b = Thread.new do
      described_class.new(@path).transaction do |data|
        order << :b
        data.merge("b" => true)
      end
    end

    [thread_a, thread_b].each(&:join)

    expect([order.pop, order.pop, order.pop]).to eq(%i[a_start a_end b])
    expect(store.read).to eq("a" => true, "b" => true)
  end
end
