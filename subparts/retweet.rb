# frozen_string_literal: true

module Plugin::Twitter
  class Retweet < Plugin::Subparts::Voter
    def self.instances
      @@instances ||= {}
    end

    def initialize(model)
      @model = model

      super()

      self.class.instances[model.uri] = self
    end

    attr_reader :model

    def icon
      ::Skin[:retweet]
    end

    def count
      model.retweet_count
    end

    def voters_d
      model.retweeted_by_d
    end
  end
end
