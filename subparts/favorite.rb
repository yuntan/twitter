# frozen_string_literal: true

module Plugin::Twitter
  class Favorite < Plugin::Subparts::Voter
    def self.instances
      @@instances ||= {}
    end

    def initialize(model)
      super

      self.class.instances[model.uri] = self
    end

    def icon
      ::Skin[:unfav]
    end

    def count
      model.favorite_count
    end

    def voters
      model.favorited_by
    end
  end
end
