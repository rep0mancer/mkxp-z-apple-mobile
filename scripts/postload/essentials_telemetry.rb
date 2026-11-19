# SPDX-License-Identifier: GPL-3.0-only
# Loaded before Main on an RGSS1 host with a telemetry receiver. The native
# sampler runs this block on the Ruby thread at most twice a second.
module EmpoEssentialsTelemetry
  class << self
    def recognized?
      defined?(Essentials::VERSION) &&
        Essentials::VERSION.to_s =~ /\A(?:19|20|21)(?:\.\d+)*\z/ &&
        (defined?(GameData::Species) || defined?(PBSpecies))
    rescue StandardError
      false
    end

    # pbStartBattle owns the battle through its entire nested scene loop on
    # both PokeBattle_Battle (19) and Battle (20/21). Preserve the result,
    # blocks, exceptions and any outer battle when a game nests this call.
    def during_battle(battle)
      preceding = @battle
      @battle = battle
      begin
        yield
      ensure
        @battle = preceding
      end
    end

    def attach
      klass = Battle if defined?(Battle) && Battle.is_a?(Class) && Battle.method_defined?(:pbStartBattle)
      klass ||= PokeBattle_Battle if defined?(PokeBattle_Battle)
      if klass.is_a?(Class) && klass.method_defined?(:pbStartBattle)
        if klass.respond_to?(:prepend)
          klass.send(:prepend, BattleLifetime) unless klass.ancestors.include?(BattleLifetime)
        elsif !klass.private_method_defined?(:__empo_original_battle_start)
          klass.class_eval do
            alias_method :__empo_original_battle_start, :pbStartBattle
            private :__empo_original_battle_start
            def pbStartBattle(*args, &block)
              EmpoEssentialsTelemetry.during_battle(self) { __empo_original_battle_start(*args, &block) }
            end
          end
        end
      end
      true
    rescue StandardError
      # A fork may freeze or replace its battle class. The party and map
      # can still be sampled without wrapping that class.
      true
    end

    def install
      @last = @last_json = @battle = @legacy_ids = @table = @route = nil
      ready = recognized? && attach
      System.__register_essentials_telemetry do
        # A single-file loader may define Essentials in Main; give it one
        # Graphics checkpoint. Ordinary non-Essentials games then unregister.
        ready ||= recognized? && attach
        ready ? sample : false
      end
    end
  end

  module BattleLifetime
    def pbStartBattle(*args, &block)
      EmpoEssentialsTelemetry.during_battle(self) { super(*args, &block) }
    end
  end

  # Older forks carry numeric database IDs. Cache their actual constant names;
  # displaying local enum indexes as species/types would give wrong matchups.
  LEGACY = { :Species => :PBSpecies, :Type => :PBTypes, :Move => :PBMoves,
             :Status => :PBStatuses, :Item => :PBItems, :Stat => :PBStats } unless const_defined?(:LEGACY)

  class << self
    private

    def read(obj, method, *args)
      obj.send(method, *args) if obj && obj.respond_to?(method)
    rescue StandardError
      nil
    end

    def text(value, limit = 96)
      return nil unless value.is_a?(String) || value.is_a?(Symbol)
      str = value.to_s[0, limit]
      if str.respond_to?(:encoding)
        str.force_encoding('UTF-8') if str.encoding.name == 'ASCII-8BIT'
        str = str.encode('UTF-8') unless str.encoding.name == 'UTF-8'
        return nil unless str.valid_encoding?
      else
        str.unpack('U*') # reject invalid UTF-8 on Ruby 1.8
      end
      str
    rescue StandardError
      nil
    end

    def identifier(value, kind)
      if value.is_a?(Integer)
        return nil if value < 0
        registry = GameData.const_get(kind) if defined?(GameData) && GameData.const_defined?(kind)
        record = read(registry, :try_get, value)
        current = text(read(record, :id), 64)
        return current if current
        @legacy_ids ||= {}
        unless @legacy_ids[kind]
          ids = {}
          if Object.const_defined?(LEGACY[kind])
            mod = Object.const_get(LEGACY[kind])
            mod.constants.each do |name|
              next if name.to_s == 'MAXVALUE' || (mod.respond_to?(:autoload?) && mod.autoload?(name))
              n = mod.const_get(name)
              ids[n] = name.to_s if n.is_a?(Integer)
            end
          end
          @legacy_ids[kind] = ids
        end
        return @legacy_ids[kind][value]
      end
      value = read(value, :id) unless value.is_a?(String) || value.is_a?(Symbol)
      return nil unless value.is_a?(String) || value.is_a?(Symbol)
      id = text(value, 65)
      id if id && !id.empty? && id.size <= 64
    rescue StandardError
      nil
    end

    def number(n, min = 0)
      n if n.is_a?(Integer) && n >= min && n <= 2147483647
    end

    def types(obj, battler = false)
      ids = read(obj, :pbTypes, true) || read(obj, :pbTypes) if battler
      ids ||= read(obj, :types)
      if !ids
        first = read(obj, :type1)
        if first
          ids = [first, read(obj, :type2)]
        elsif defined?(GameData::Species)
          # form can invoke game callbacks and change the Pokemon. form_simple
          # reads the forced/current form without calculating a new one.
          species = read(obj, :species)
          data = read(GameData::Species, :get_species_form, species, read(obj, :form_simple) || 0)
          data ||= read(GameData::Species, :try_get, species)
          ids = read(data, :types) || [read(data, :type1), read(data, :type2)]
        end
      end
      return [] unless ids.is_a?(Array)
      ids.first(8).map { |id| identifier(id, :Type) }.compact.uniq
    end

    def move(obj)
      id = identifier(read(obj, :id), :Move)
      pp = number(read(obj, :pp))
      max = number(read(obj, :total_pp) || read(obj, :totalpp))
      return nil unless id && pp && max
      { 'id' => id, 'pp' => pp, 'maxPP' => max }
    end

    def member(obj)
      species = identifier(read(obj, :species), :Species)
      hp = number(read(obj, :hp))
      max = number(read(obj, :totalhp), 1)
      level = number(read(obj, :level), 1)
      return nil unless species && hp && max && level
      status = read(obj, :status)
      status = identifier(status, :Status) unless status == 0
      item = obj.respond_to?(:item_id) ? read(obj, :item_id) : read(obj, :item)
      moves = read(obj, :moves)
      { 'species' => species, 'nickname' => text(read(obj, :name)) || species,
        'level' => level, 'hp' => hp, 'maxHP' => max,
        'status' => (status == 0 || status == 'NONE' ? nil : status),
        'item' => (item == 0 ? nil : identifier(item, :Item)), 'types' => types(obj),
        'moves' => moves.is_a?(Array) ? moves.first(16).map { |m| move(m) }.compact : [] }
    end

    def stages(obj)
      raw = read(obj, :stages)
      result = {}
      if raw.is_a?(Hash) && raw.size <= 32
        raw.each do |stat, n|
          id = identifier(stat, :Stat)
          result[id] = n if id && number(n, -2147483648)
        end
      elsif raw.is_a?(Array)
        raw.first(16).each_with_index do |n, i|
          id = identifier(i, :Stat)
          result[id] = n if id && number(n, -2147483648)
        end
      end
      result
    end

    def battle_state
      list = read(@battle, :battlers)
      return nil unless list.is_a?(Array)
      allies, opponents = [], []
      list.first(32).each do |b|
        index = number(read(b, :index))
        species = identifier(read(b, :species), :Species)
        hp, max = number(read(b, :hp)), number(read(b, :totalhp), 1)
        next unless index && species && hp && max
        opposing = read(b, :opposes?)
        opposing = index % 2 == 1 unless opposing == true || opposing == false
        (opposing ? opponents : allies) << {
          'index' => index, 'species' => species, 'types' => types(b, true),
          'hpPercent' => [[(hp * 100 + max / 2) / max, 100].min, 0].max,
          'stages' => stages(b) }
      end
      { 'allies' => allies, 'opponents' => opponents }
    end

    def encounter_slots(table)
      return nil unless table.is_a?(Hash) && table.size <= 64
      result = []
      table.each do |method, slots|
        method_name = text(method, 64)
        next unless method_name && slots.is_a?(Array)
        slots.each do |slot|
          next unless slot.is_a?(Array)
          weight, raw_species, lo, hi = slot
          species = identifier(raw_species, :Species)
          hi ||= lo
          next unless species && number(weight, 1) && number(lo, 1) && number(hi, lo)
          result << [raw_species, { 'method' => method_name, 'weight' => weight, 'species' => species,
                                    'minLevel' => lo, 'maxLevel' => hi }]
        end
      end
      result
    end

    def flag(value)
      value if value == true || value == false
    end

    def encounters(map_id, player)
      return nil unless map_id && defined?(GameData::Encounter)
      version = number(read(defined?($PokemonGlobal) && $PokemonGlobal, :encounter_version)) || 0
      record = read(GameData::Encounter, :get, map_id, version)
      return nil unless record
      table = read(record, :types)
      return nil unless table.is_a?(Hash) && table.size <= 64
      # Reuse slot rows when walking around. Re-evaluate seen/owned flags
      # for just the species on this map, including after a capture.
      count = 0
      table.each_value do |slots|
        count += slots.size if slots.is_a?(Array)
        return nil if count > 256
      end
      key = [map_id, version, table.hash]
      unless table.equal?(@table) && key == @table_key
        @table, @table_key = table, key
        @slots = encounter_slots(table)
        @route_species = @slots && @slots.map { |pair| pair[0] }.uniq
        @route = @dex_flags = nil
      end
      return nil unless @slots
      dex = read(player, :pokedex) || player
      flags = {}
      @route_species.each do |species|
        flags[species] = [flag(read(dex, :seen?, species)), flag(read(dex, :owned?, species))]
      end
      if flags != @dex_flags
        @dex_flags = flags
        @route = @slots.map do |raw, row|
          seen, caught = flags[raw]
          row.merge('seen' => seen, 'caught' => caught)
        end
      end
      @route
    end

    def on_title?
      defined?($scene) && (!$scene ||
        (defined?(Scene_Intro) && $scene.is_a?(Scene_Intro)) ||
        (defined?(Scene_DebugIntro) && $scene.is_a?(Scene_DebugIntro)) ||
        (defined?(Scene_Title) && $scene.is_a?(Scene_Title)))
    end

    # Emit strict, compact JSON for this closed set of primitive types on all
    # three embedded Rubies; the oldest MRI does not ship the json gem.
    def json(obj)
      case obj
      when String
        '"' + obj.gsub(/["\\\x00-\x1f]/) { |c|
          c == '"' || c == '\\' ? '\\' + c : '\\u%04x' % c.unpack('C')[0]
        } + '"'
      when Integer then obj.to_s
      when Array then '[' + obj.map { |v| json(v) }.join(',') + ']'
      when Hash then '{' + obj.map { |k, v| json(k) + ':' + json(v) }.join(',') + '}'
      when TrueClass then 'true'
      when FalseClass then 'false'
      when NilClass then 'null'
      end
    end

    def sample
      map = party = route = battle = nil
      unless on_title?
        player = defined?($player) && $player
        roster = read(player, :party)
        unless roster.is_a?(Array)
          player = defined?($Trainer) && $Trainer
          roster = read(player, :party)
        end
        if roster.is_a?(Array)
          game_map = defined?($game_map) && $game_map
          id = number(read(game_map, :map_id), 1)
          if id
            name = text(read(game_map, :name))
            if !name && defined?(GameData::MapMetadata)
              name = text(read(read(GameData::MapMetadata, :try_get, id), :name))
            end
            map = { 'id' => id, 'name' => name || '' }
          end
          party = roster.first(32).map { |p| member(p) }.compact
          route = encounters(id, player)
          battle = battle_state if @battle
        end
      end
      return nil if !party && !@last
      state = { 'schemaVersion' => 1, 'map' => map, 'party' => party || [],
                'encounters' => route, 'battle' => battle }
      return nil if state == @last
      payload = json(state)
      if payload.bytesize > 65536 && route
        payload = json(state.merge('encounters' => nil))
      end
      if payload.bytesize > 65536
        # Extremely large or incompatible forks clear any previous dashboard.
        payload = '{"schemaVersion":1,"map":null,"party":[],"encounters":null,"battle":null}'
      end
      @last = state
      return nil if @last_json == payload
      @last_json = payload
    rescue StandardError
      # Optional game APIs may be redefined while a scene is tearing down.
      # Clear a live snapshot once; let the next native tick probe again.
      blank = '{"schemaVersion":1,"map":null,"party":[],"encounters":null,"battle":null}'
      return nil unless @last_json && @last_json != blank
      @last = nil
      @last_json = blank
    end
  end
end

if defined?(System) && System.respond_to?(:__register_essentials_telemetry)
  EmpoEssentialsTelemetry.install
end
