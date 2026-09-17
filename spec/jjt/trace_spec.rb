# frozen_string_literal: true

RSpec.describe Jjt::Trace do
  around do |example|
    original = ENV.fetch("JJT_DEBUG", nil)
    example.run
  ensure
    ENV["JJT_DEBUG"] = original
  end

  context "when JJT_DEBUG is unset" do
    before { ENV.delete("JJT_DEBUG") }

    it "runs the block without printing anything" do
      expect { expect(described_class.step("thing") { 42 }).to eq(42) }.not_to output.to_stderr
    end
  end

  context "when JJT_DEBUG is set" do
    before { ENV["JJT_DEBUG"] = "1" }

    it "runs the block and prints its label and elapsed time to stderr" do
      result = nil
      expect { result = described_class.step("thing") { 42 } }.to output(/jjt: \[debug\] thing: \d+\.\d\ds/).to_stderr
      expect(result).to eq(42)
    end

    it "still prints and re-raises when the block raises" do
      expect do
        described_class.step("thing") { raise "boom" }
      end.to output(/jjt: \[debug\] thing/).to_stderr.and raise_error("boom")
    end
  end
end
