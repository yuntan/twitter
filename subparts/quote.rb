# frozen_string_literal: true

module Plugin::Twitter
  class Quote < Plugin::Subparts::Status
    def initialize(child_model)
      @child_model = child_model

      super()
    end

    def model_d
      @child_model.quoted_status_d
    end
  end
end
