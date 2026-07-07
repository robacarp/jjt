# frozen_string_literal: true

require_relative "lib/jjt/version"

Gem::Specification.new do |spec|
  spec.name = "jjt"
  spec.version = Jjt::VERSION
  spec.authors = ["Rob Carpenter"]
  spec.email = ["208647+robacarp@users.noreply.github.com"]

  spec.summary = "A pool manager for reusable jj workspaces"
  spec.description = "jjt manages a pool of reusable jj workspaces, analogous to " \
                      "treehouse for git worktrees, but built on `jj workspace`."
  spec.homepage = "https://github.com/robacarp/jjt"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "bin"
  spec.executables = spec.files.grep(%r{\Abin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.5"
  spec.add_dependency "tomlib", "~> 0.7"

  spec.add_development_dependency "rspec", "~> 3.13"
end
