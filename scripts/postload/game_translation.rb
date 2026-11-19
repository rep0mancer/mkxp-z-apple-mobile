# SPDX-License-Identifier: GPL-3.0-only
# Bundled RGSS1 postload. Only dialogue presentation receives replacement strings.
# The window still handles text animation, sound effects, input and event branches.
module EmpoGameTranslation
  SEPARATOR = "\x1f" unless const_defined?(:SEPARATOR)
  MAX_BYTES = 16384 unless const_defined?(:MAX_BYTES)
  MAX_SEGMENTS = 128 unless const_defined?(:MAX_SEGMENTS)

  # Bracket commands carry filenames, variables and (for \\ch) a CSV index and
  # labels. Essentials calls pbShowCommands with the parsed labels later.
  # A fork's bare command can start with a stock command, e.g. \\rainbow.
  # Keep the full identifier except for the stock lowercase formatting markers
  # immediately before a capitalized word, as in \\bBlue.
  CONTROL = /\\(?:[a-zA-Z_][a-zA-Z_0-9]*\[[^\[\]\r\n]*\]|\[[^\[\]\r\n]*\]|(?-i:[bnr](?=[A-Z][a-z]+(?![a-zA-Z_0-9])))|[a-zA-Z_][a-zA-Z_0-9]*|[^\r\n])|<[^<>\r\n]+>|%?\{[^{}\r\n]+\}|%(?:[0-9]+\$)?[-+0-9.]*[sdif]|[\x00-\x1f\x7f]/i unless const_defined?(:CONTROL)
  UNSAFE_RESULT = /[\\<>{}\[\]\x00-\x1f\x7f]|%(?:[0-9]+\$)?[-+0-9.]*[sdif]/ unless const_defined?(:UNSAFE_RESULT)

  class << self
    def utf8(s)
      return nil unless s.is_a?(String)
      if s.respond_to?(:force_encoding)
        str = s.dup.force_encoding('UTF-8')
        return str if str.valid_encoding?
      else
        codepoints = s.unpack('U*')
        return s if codepoints.pack('U*') == s &&
          !codepoints.any? { |c| c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff) }
      end
      nil
    rescue StandardError
      nil
    end

    def byte_size(s)
      s.respond_to?(:bytesize) ? s.bytesize : s.size
    end

    def display_names(scene)
      player = $player if defined?($player)
      player ||= $Trainer if defined?($Trainer)
      objects = [player]
      party = player.party if player && player.respond_to?(:party)
      objects.concat(party[0, 12]) if party.is_a?(Array)
      battle = scene.instance_variable_get(:@battle)
      battlers = battle.battlers if battle && battle.respond_to?(:battlers)
      objects.concat(battlers[0, 12]) if battlers.is_a?(Array)
      names = []
      objects.each do |obj|
        next unless obj && obj.respond_to?(:name)
        name = utf8(obj.name)
        names << name if name && !name.strip.empty? && byte_size(name) <= 96
      end
      names.uniq.sort_by { |name| -name.size }
    rescue StandardError
      []
    end

    def protected_pattern(scene)
      names = display_names(scene)
      return /(#{CONTROL})/ if names.empty?
      # Old MRI treats some non-ASCII letters as non-word characters. Add
      # boundaries only at ASCII word edges, so "Flabébé" and "Nidoran♀" survive.
      escaped = names.map do |name|
        left = name =~ /\A[a-zA-Z0-9_]/ ? '\b' : ''
        right = name =~ /[a-zA-Z0-9_]\z/ ? '\b' : ''
        left + Regexp.escape(name) + right
      end
      /((?:#{CONTROL})|(?:#{escaped.join('|')}))/
    end

    # Send each unique span once; keep separators, surrounding whitespace and
    # protected tokens on the Ruby side. Only a complete validated batch wins.
    def translate(values, scene)
      return values if @waiting || values.empty? || values.size > MAX_SEGMENTS
      return values if values.inject(0) { |n,s| n + byte_size(s) } > MAX_BYTES
      pat = protected_pattern(scene)
      queries = []
      indices = {}
      plans = values.map do |raw|
        text = utf8(raw)
        return values unless text && !text.include?(SEPARATOR)
        next nil if @showing && @showing.include?(raw)
        tokens = text.split(pat, -1)
        tokens.each_index do |i|
          next if i % 2 == 1
          part = tokens[i]
          next if part.strip.empty?
          # An unclosed tag or command parameter is ambiguous in a fork.
          return values if part =~ /[\\<>\[\]{}]/
          m = /\A( *)(.*?)( *)\z/m.match(part)
          word = m[2]
          next unless word =~ /[A-Za-z]/ || word.unpack('U*').any? { |c| c > 127 }
          index = indices[word]
          unless index
            return values if queries.size >= MAX_SEGMENTS
            index = queries.length
            indices[word] = index
            queries << word
          end
          tokens[i] = [index, m[1], m[3]]
        end
        tokens
      end
      return values if queries.empty?
      request = queries.join(SEPARATOR)
      return values if byte_size(request) > MAX_BYTES
      @waiting = true
      begin
        id = System.__game_translation_start(request)
        return values unless id
        reply = nil
        loop do
          reply = System.__game_translation_result(id)
          break unless reply.nil?
          # Gives MKXP its pause/quit checkpoints and keeps the last frame on
          # screen. Native expiry uses wall time even when fast-forward is on.
          Graphics.update
        end
      ensure
        @waiting = false
      end
      return values unless reply.is_a?(String) && byte_size(reply) <= MAX_BYTES
      reply = utf8(reply)
      return values unless reply
      translated = reply.split(SEPARATOR, -1)
      return values unless translated.length == queries.length &&
        translated.all? { |s| !s.strip.empty? && s !~ UNSAFE_RESULT }
      rebuilt = []
      plans.each_with_index do |parts, row|
        if parts
          chunks = parts.map do |p|
            if p.is_a?(Array)
              chunk = p[1] + translated[p[0]] + p[2]
              yield(p[1] + queries[p[0]] + p[2], chunk) if block_given?
              chunk
            else
              yield(p, p) if block_given?
              p
            end
          end
          rebuilt << chunks.join
        else
          rebuilt << values[row]
        end
      end
      rebuilt
    rescue StandardError
      values
    end

    # Collect text and choice arrays into one request; all other arguments and
    # the original block go directly to the game. Originals may be frozen.
    def present(scene, args, slots)
      values = []
      slots.each do |i|
        field = args[i]
        if field.is_a?(String)
          values << field
        elsif field.is_a?(Array) && field.all? { |s| s.is_a?(String) }
          values.concat(field)
        end
      end
      translated = translate(values, scene)
      return yield(args) if translated.equal?(values) || translated == values
      display = args.dup
      cursor = 0
      slots.each do |i|
        field = args[i]
        if field.is_a?(String)
          display[i] = translated[cursor]
          cursor += 1
        elsif field.is_a?(Array) && field.all? { |s| s.is_a?(String) }
          display[i] = translated[cursor, field.size]
          cursor += field.size
        end
      end
      previous = @showing
      @showing = (previous || []) + translated
      begin
        yield(display)
      ensure
        @showing = previous
      end
    end

    # Recover source spans after a custom refresh consumes a prefix. At a
    # boundary (including a newline or control) the source suffix is exact.
    # Inside a translated word keep its remaining glyphs in display language.
    def remaining_spans(spans, display, rest)
      return [] if rest.empty?
      offset = display.size - rest.size
      return [[rest, rest]] unless offset >= 0 && display[offset..-1] == rest
      spans.each_with_index do |pair, i|
        shown = pair[1]
        if offset == 0
          return spans[i..-1]
        elsif offset < shown.size
          tail = shown[offset..-1]
          return [[tail, tail]] + spans[i + 1..-1]
        end
        offset -= shown.size
      end
      [[rest, rest]]
    end

    def stock_refresh(window)
      temp = $game_temp
      return yield unless temp.is_a?(Game_Temp)
      source = temp.message_text
      cache = @stock_remaining
      @stock_remaining = nil
      return yield unless source.is_a?(String) && !source.frozen?
      if cache && source.equal?(cache[0]) && source == cache[1]
        display, spans = cache[2], cache[3]
      else
        spans = []
        display = translate([source], window) { |orig, shown| spans << [orig, shown] }[0]
        return yield if display == source
      end
      text = display.dup
      temp.message_text = text
      begin
        yield
      ensure
        rest = temp.message_text
        if rest.equal?(text)
          spans = remaining_spans(spans, display, rest)
          source.replace(spans.map { |pair| pair[0] }.join)
          temp.message_text = source
          @stock_remaining = [source, source.dup, rest.dup, spans] unless rest.empty?
        elsif rest.is_a?(String) && !rest.empty? && rest.size < display.size &&
            display[-rest.size, rest.size] == rest
          # Some windows assign a new substring instead of mutating this one.
          # Honor the replacement object's identity and avoid translating it twice.
          copy = rest.dup
          @stock_remaining = [rest, copy, copy, [[copy, copy]]]
        end
      end
    end

    def wrap(owner, name, slots)
      return unless owner && (owner.method_defined?(name) || owner.private_method_defined?(name))
      original = owner.instance_method(name)
      @installed ||= {}
      key = [owner, name]
      return if @installed[key] == original
      visibility = owner.private_method_defined?(name) ? :private :
        (owner.protected_method_defined?(name) ? :protected : :public)
      owner.send(:define_method, name) do |*args, &block|
        if slots
          EmpoGameTranslation.present(self, args, slots) { |display| original.bind(self).call(*display, &block) }
        else
          EmpoGameTranslation.stock_refresh(self) { original.bind(self).call(*args, &block) }
        end
      end
      owner.send(visibility, name)
      @installed[key] = owner.instance_method(name)
    rescue StandardError
      # A fork may replace a method or freeze one individual class.
      nil
    end

    def install
      return unless System.respond_to?(:__game_translation_start) && System.respond_to?(:__game_translation_result)
      if Object.const_defined?(:Essentials) && Essentials.is_a?(Module) &&
          Essentials.const_defined?(:VERSION)
        return unless Essentials::VERSION.to_s =~ /\A(?:19|20|21)(?:\.\d+)*\z/ &&
          ((Object.const_defined?(:GameData) && GameData.const_defined?(:Species)) || Object.const_defined?(:PBSpecies))
        wrap(Object, :pbMessageDisplay, [1])
        wrap(Object, :pbShowCommands, [1])
        wrap(Object, :pbShowCommandsWithHelp, [1, 2])
        # Some forks define singleton methods on Kernel alongside global methods.
        singleton = class << Kernel; self; end
        [:pbMessageDisplay, :pbShowCommands, :pbShowCommandsWithHelp].each do |name|
          if singleton.instance_methods(false).map { |m| m.to_s }.include?(name.to_s)
            wrap(singleton, name, name == :pbShowCommandsWithHelp ? [1, 2] : [1])
          end
        end
        scene = Battle::Scene if Object.const_defined?(:Battle) && Battle.is_a?(Module) &&
          Battle.const_defined?(:Scene) && Battle::Scene.is_a?(Class)
        scene ||= PokeBattle_Scene if defined?(PokeBattle_Scene) && PokeBattle_Scene.is_a?(Class)
        [:pbDisplayMessage, :pbDisplay, :pbDisplayPausedMessage].each { |m| wrap(scene, m, [0]) }
        wrap(scene, :pbShowCommands, [0, 1])
      elsif defined?(Window_Message) && defined?(Window_Selectable) && defined?(Game_Temp) &&
          Window_Message.is_a?(Class) && Window_Message < Window_Selectable && Game_Temp.is_a?(Class) &&
          [:message_text, :message_text=, :choice_start, :num_input_start].all? { |m| Game_Temp.method_defined?(m) } &&
          [:terminate_message, :reset_window, :update_cursor_rect].all? { |m| Window_Message.method_defined?(m) }
        wrap(Window_Message, :refresh, nil)
      end
    rescue StandardError
      nil
    end
  end
end

EmpoGameTranslation.install
