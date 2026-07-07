# frozen_string_literal: true

require_relative "jjt/version"

module Jjt
  class Error < StandardError; end
end

require_relative "jjt/config"
require_relative "jjt/store"
require_relative "jjt/cli"
