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
        game_data&.dig(:settings, :human_player_index) || 0
      end

      def ai_acting?(game, game_data)
        return false unless game && !game.finished
        return false unless ai_players?(game_data)

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

      def fetch_ai_move(game_data)
        payload = { game_data: game_data }.to_n

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
            console.error('AI server error:', err)
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
        end

        # Apply next action with delay if more remain
        if idx + 1 < actions.length
          %x{
            setTimeout(function() {
              #{apply_ai_actions(actions, idx + 1)}
            }, #{AI_MOVE_DELAY_MS})
          }
        else
          # Release lock — postpatch from the last process_action
          # re-render will call maybe_trigger_ai_move.
          @ai_pending = false
        end
      end

      def intent_to_action_h(intent)
        type = intent['type']
        entity = @game.round.current_entity

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
        when 'acquire'
          build_acquire_h(entity, intent)
        when 'acquire_fi'
          build_acquire_fi_h(entity, intent)
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

      def build_acquire_h(_entity, intent)
        corp = @game.corporation_by_id(intent['corporation'])
        company = @game.company_by_id(intent['company'])

        # Acquisition in RSS: corp responds to its own offer to buy
        {
          'type' => 'respond',
          'entity' => corp.owner.id,
          'entity_type' => 'player',
          'corporation' => corp.id,
          'company' => company.id,
          'accept' => 'true',
        }
      end

      def build_acquire_fi_h(_entity, intent)
        corp = @game.corporation_by_id(intent['corporation'])
        company = @game.company_by_id(intent['company'])

        {
          'type' => 'respond',
          'entity' => corp.owner.id,
          'entity_type' => 'player',
          'corporation' => corp.id,
          'company' => company.id,
          'accept' => 'true',
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
