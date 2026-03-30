# frozen_string_literal: true

# backtick_javascript: true

require 'lib/settings'
require 'lib/storage'
require 'view/welcome'

module View
  class Home < Snabberb::Component
    include Lib::Settings

    needs :user

    def render
      `document.title = 'Rolling Stock Stars'`

      props = {
        key: 'home_page',
      }

      h('div#homepage', props, [
        h(Welcome),
      ])
    end
  end
end
