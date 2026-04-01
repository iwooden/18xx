# frozen_string_literal: true

# backtick_javascript: true

# AI Bridge: detects when an AI player is acting in a hotseat game,
# fetches the move from the Python AI server, constructs the proper
# Engine::Action, and applies it via process_action.

module View
  module Game
    module AiBridge
      AI_SERVER_URL = 'http://localhost:5050'
      AI_MOVE_DELAY_MS = 600

      def ai_players?(game_data)
        game_data&.dig(:settings, :human_player_index) != nil
      end

      def human_player_index(game_data)
        game_data&.dig(:settings, :human_player_index)
      end

      def spectator_mode?(game_data)
        human_player_index(game_data) == -1
      end

      def ai_acting?(game, game_data)
        return false unless game && !game.finished
        return false unless ai_players?(game_data)

        # Spectator mode: all players are AI
        return true if spectator_mode?(game_data)

        human_idx = human_player_index(game_data)
        acting = game.active_players_id
        return false if acting.nil? || acting.empty?

        # Check if any acting player is AI (not the human)
        acting.any? { |pid| pid != human_idx }
      end

      def maybe_trigger_ai_move
        return unless hotseat?
        return if @ai_pending
        return unless ai_acting?(@game, @game_data)

        @ai_pending = true
        game_data_copy = @game_data

        # Small delay so human can see the board state
        %x{
          setTimeout(function() {
            #{fetch_ai_move(game_data_copy)}
          }, #{AI_MOVE_DELAY_MS})
        }
      end

      def build_state_checksum
        players = @game.players.map do |p|
          {
            name: p.name,
            cash: p.cash,
            value: p.value,
            companies: p.companies.map(&:sym).sort,
          }
        end

        corps = @game.corporations.select(&:floated?).map do |c|
          {
            name: c.id,
            cash: c.cash,
            share_price: c.share_price&.price,
            companies: c.companies.map(&:sym).sort,
          }
        end

        { players: players, corps: corps }
      end

      def fetch_ai_move(game_data)
        checksum = build_state_checksum
        payload = { game_data: game_data, state_checksum: checksum }.to_n

        %x{
          fetch(#{AI_SERVER_URL + '/api/ai-move'}, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
          })
          .then(function(res) { return res.json() })
          .then(function(data) {
            #{handle_ai_response(`Opal.Hash.$new(data)`)}
          })
          .catch(function(err) {
            console.error('AI server error:', err);
            #{@ai_pending = false}
            #{store(:flash_opts, 'AI server error — is the server running?')}
          })
        }
      end

      def handle_ai_response(data)
        actions = data['actions']
        if actions.nil? || actions.empty?
          @ai_pending = false
          return
        end

        apply_ai_actions(actions.to_a, 0)
      end

      def apply_ai_actions(actions, idx)
        if idx >= actions.length
          # All actions applied — release the lock so postpatch can
          # trigger the next AI move on the next re-render cycle.
          @ai_pending = false
          return
        end

        intent = actions[idx]
        action_h = intent_to_action_h(intent)

        if action_h
          begin
            action = Engine::Action::Base.action_from_h(action_h, @game)
            process_action(action)
          rescue StandardError => e
            @ai_pending = false
            LOGGER.error("AI bridge: failed to apply action: #{e.message}")
            store(:flash_opts, "AI action failed: #{e.message}")
            return
          end
        else
          # action_h was nil — no process_action ran, so no re-render
          # will trigger maybe_trigger_ai_move.  Schedule a deferred
          # re-trigger to keep the AI move loop alive.
          LOGGER.warn("AI bridge: skipping nil action for intent: #{intent}")
          @ai_pending = false
          %x{
            setTimeout(function() { #{maybe_trigger_ai_move} }, #{AI_MOVE_DELAY_MS})
          }
          return
        end

        # Apply next action with delay if more remain
        if idx + 1 < actions.length
          %x{
            setTimeout(function() {
              #{apply_ai_actions(actions, idx + 1)}
            }, #{AI_MOVE_DELAY_MS})
          }
        else
          @ai_pending = false
        end
      end

      def intent_to_action_h(intent)
        type = intent['type']
        entity = @game.round.current_entity
        step = @game.round.active_step

        # When the 18xx engine is in the receivership step (right-of-first-
        # refusal), the only valid action is "respond".  Our engine auto-
        # handles receivership buys, so we decline intervention.
        if step.is_a?(Engine::Game::GRollingStock::Step::ReceiverProposeAndPurchase)
          return build_receiver_decline_h(entity)
        end

        case type
        when 'pass', 'close_pass', 'acq_pass'
          build_pass_h(entity)
        when 'bid'
          build_bid_h(entity, intent)
        when 'buy_shares'
          build_buy_shares_h(entity, intent)
        when 'sell_shares'
          build_sell_shares_h(entity, intent)
        when 'par'
          build_par_h(entity, intent)
        when 'dividend'
          build_dividend_h(entity, intent)
        when 'issue'
          build_issue_h(entity, intent)
        when 'offer'
          build_offer_h(entity, intent)
        when 'respond'
          build_respond_h(intent)
        when 'close'
          build_close_h(entity, intent)
        else
          LOGGER.error("AI bridge: unknown intent type: #{type}")
          nil
        end
      end

      def build_pass_h(entity)
        etype = if entity.player?
                  'player'
                elsif entity.corporation?
                  'corporation'
                elsif entity.company?
                  'company'
                else
                  'player'
                end

        {
          'type' => 'pass',
          'entity' => entity.id,
          'entity_type' => etype,
        }
      end

      def build_bid_h(entity, intent)
        {
          'type' => 'bid',
          'entity' => entity.id,
          'entity_type' => 'player',
          'company' => intent['company'],
          'price' => intent['price'],
        }
      end

      def build_buy_shares_h(entity, intent)
        corp = @game.corporation_by_id(intent['corporation'])

        # Find the first buyable share: IPO first, then market
        share = corp.ipo_shares.first || @game.share_pool.shares_by_corporation[corp]&.first

        return nil unless share

        {
          'type' => 'buy_shares',
          'entity' => entity.id,
          'entity_type' => 'player',
          'shares' => [share.id],
          'percent' => share.percent,
        }
      end

      def build_sell_shares_h(entity, intent)
        corp = @game.corporation_by_id(intent['corporation'])

        # Find a share the player owns (non-president share first)
        player_shares = entity.shares_by_corporation[corp] || []
        share = player_shares.reject(&:president).first || player_shares.first

        return nil unless share

        {
          'type' => 'sell_shares',
          'entity' => entity.id,
          'entity_type' => 'player',
          'shares' => [share.id],
          'percent' => share.percent,
        }
      end

      def build_par_h(_entity, intent)
        # In RSS, the IPO entity is the company being converted
        company = @game.company_by_id(intent['company'])

        {
          'type' => 'par',
          'entity' => company.id,
          'entity_type' => 'company',
          'corporation' => intent['corporation'],
          'share_price' => intent['share_price'],
        }
      end

      def build_dividend_h(entity, intent)
        {
          'type' => 'dividend',
          'entity' => entity.id,
          'entity_type' => 'corporation',
          'kind' => 'variable',
          'amount' => intent['amount'],
        }
      end

      def build_issue_h(entity, intent)
        # Issue = corp sells a share from treasury (IPO)
        share = entity.ipo_shares.first
        return nil unless share

        {
          'type' => 'sell_shares',
          'entity' => entity.id,
          'entity_type' => 'corporation',
          'shares' => [share.id],
          'percent' => share.percent,
        }
      end

      def build_receiver_decline_h(entity)
        # Decline right-of-first-refusal for a receivership FI purchase.
        # Find the pending offer where this entity is the responder.
        offer = @game.round.offers.find { |o| o[:responder] == entity }
        return build_pass_h(entity) unless offer

        {
          'type' => 'respond',
          'entity' => entity.id,
          'entity_type' => 'player',
          'corporation' => offer[:corporation].id,
          'company' => offer[:company].id,
          'accept' => 'false',
        }
      end

      def build_offer_h(entity, intent)
        {
          'type' => 'offer',
          'entity' => entity.id,
          'entity_type' => 'player',
          'corporation' => intent['corporation'],
          'company' => intent['company'],
          'price' => intent['price'],
        }
      end

      def build_respond_h(intent)
        # After an offer is processed, the 18xx engine sets
        # current_entity to the company owner (the responder).
        entity = @game.round.current_entity
        {
          'type' => 'respond',
          'entity' => entity.id,
          'entity_type' => 'player',
          'corporation' => intent['corporation'],
          'company' => intent['company'],
          'accept' => intent['accept'] || 'true',
        }
      end

      def build_close_h(entity, intent)
        company = @game.company_by_id(intent['company'])

        {
          'type' => 'sell_company',
          'entity' => entity.id,
          'entity_type' => 'player',
          'company' => company.id,
          'price' => 0,
        }
      end
    end
  end
end
