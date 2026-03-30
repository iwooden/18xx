# frozen_string_literal: true

# backtick_javascript: true

require 'game_manager'
require 'lib/storage'

module View
  class Welcome < Snabberb::Component
    include GameManager

    needs :app_route, default: nil, store: true

    RSS_TITLE = 'Rolling Stock Stars'

    def render
      @inputs = {}

      container_style = {
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        padding: '2rem',
        maxWidth: '400px',
        margin: '2rem auto',
      }

      h('div#welcome', { style: container_style }, [
        h(:h1, { style: { marginBottom: '1.5rem' } }, 'Rolling Stock Stars'),
        render_seed_input,
        render_buttons,
      ])
    end

    def render_seed_input
      input_props = {
        style: {
          width: '100%',
          padding: '0.5rem',
          fontSize: '1rem',
          marginBottom: '1rem',
          boxSizing: 'border-box',
        },
        attrs: {
          id: 'seed',
          type: 'number',
          placeholder: 'Enter game seed',
          min: 1,
        },
        on: {
          keyup: lambda { |e|
            if Native(e)['key'] == 'Enter'
              e.JS.stopPropagation
              start_game_with_seed
            end
          },
        },
      }

      input = h(:input, input_props)
      @inputs[:seed] = input
      input
    end

    def render_buttons
      button_style = {
        width: '100%',
        padding: '0.75rem',
        fontSize: '1rem',
        cursor: 'pointer',
        marginBottom: '0.5rem',
      }

      h(:div, { style: { width: '100%' } }, [
        h(:button, {
          style: button_style,
          on: { click: -> { start_game_with_seed } },
        }, 'START GAME'),
        h(:button, {
          style: button_style,
          on: { click: -> { start_game_random } },
        }, 'USE RANDOM SEED'),
      ])
    end

    def start_game_with_seed
      seed_elm = Native(@inputs[:seed])&.elm
      seed_val = seed_elm&.value.to_i
      seed_val = nil if seed_val.zero?
      launch_hotseat(seed_val)
    end

    def start_game_random
      launch_hotseat(nil)
    end

    def launch_hotseat(seed)
      settings = { optional_rules: [] }
      settings[:seed] = seed if seed

      create_hotseat(
        id: Time.now.to_i,
        players: [
          { name: 'Player 1', id: 0 },
          { name: 'Player 2', id: 1 },
          { name: 'Player 3', id: 2 },
        ],
        title: RSS_TITLE,
        description: seed ? "Seed #{seed}" : 'Random seed',
        min_players: 3,
        max_players: 3,
        settings: settings,
      )
    end
  end
end
