# frozen_string_literal: true

module Plugin::Twitter
  class Favorite < Plugin::Subparts::Voter
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
      ::Skin[:unfav]
    end

    def count
      model.favorite_count
    end

    def voters_d
      model.favorited_by_d
    end
  end
end
