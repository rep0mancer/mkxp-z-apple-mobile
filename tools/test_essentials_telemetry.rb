#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Producer fixtures model public APIs from the Maruno17 release tags.
require 'json'
require_relative 'assertion_count'

SCRIPT = File.expand_path('../scripts/postload/essentials_telemetry.rb', __dir__)

def check(actual, expected, label)
  asserted
  raise "#{label}: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

module System
  class << self
    attr_reader :probe
    def __register_essentials_telemetry(&block)
      @probe = block
    end
  end
end

def snapshot
  JSON.parse(System.probe.call)
end

def version(value)
  Essentials.send(:remove_const, :VERSION) if Essentials.const_defined?(:VERSION)
  Essentials.const_set(:VERSION, value)
end

def remove_global_constant(name)
  Object.send(:remove_const, name) if Object.const_defined?(name)
end

encounter = Struct.new(:types)
dex_type = Struct.new(:caught) do
  def seen?(species)
    species == :EEVEE
  end

  def owned?(_species)
    caught
  end
end
player_type = Struct.new(:party, :pokedex)
map_type = Struct.new(:map_id, :name)
move_type = Struct.new(:id, :pp, :total_pp)
member_type = Struct.new(:species, :name, :level, :hp, :totalhp, :status, :item_id, :moves, :types)
battler_type = Struct.new(:index, :species, :hp, :totalhp, :stages, :dynamic_types) do
  def pbTypes(extra)
    raise 'missing active extra type' unless extra
    dynamic_types
  end
end
battle_type = Class.new do
  attr_accessor :battlers
  def pbStartBattle(value, &block)
    [value, block.call]
  end
end

# A custom single-file loader can define Essentials after the engine bootstrap.
load SCRIPT
check(System.probe.call, false, 'ordinary RGSS title disables probe')
module Essentials; end
module GameData
  module Species; end
  module Encounter
    class << self
      attr_accessor :data
      def get(id, version)
        data[[id, version]]
      end
    end
  end
end
version('18.1')
load SCRIPT
check(System.probe.call, false, 'unrecognized fork disables probe')
load SCRIPT # before a custom loader has installed the supported version
version('21.1')
check(System.probe.call, nil, 'delayed detection with no player')
$PokemonGlobal = Struct.new(:encounter_version).new(0)
$scene = Object.new
class Scene_Intro; end
party_member = member_type.new(:EEVEE, "Iñé \"a\"\\雪\u0001\n", 7, 13, 19, :SLEEP, :ORANBERRY,
                               [move_type.new(:TACKLE, 3, 35)], [:NORMAL])
dex = dex_type.new(false)
actor = player_type.new([party_member], dex)
map = map_type.new(53, 'Café')
table = { :Land => [[20, :EEVEE, 2, 3], [5, :VULPIX, 7]], :OldRod => [[100, :FEEBAS, 10, 10]] }
registry = { [53, 0] => encounter.new(table), [53, 1] => encounter.new({}),
             [54, 0] => encounter.new({ :Land => [[100, :ONIX, 5, 5]] }) }
GameData::Encounter.data = registry
$game_map = map
# Distinct battlers on the same side keep their slots and live typing.
battlers = [battler_type.new(0, :EEVEE, 17, 19, { :SPEED => -2 }, [:WATER]),
            battler_type.new(1, :VULPIX, 3, 16, { :DEFENSE => 3 }, [:FIRE, :FLYING]),
            nil, battler_type.new(3, :FEEBAS, 0, 14, {}, [:WATER])]
expected = { 'species' => 'EEVEE', 'nickname' => party_member.name, 'level' => 7, 'hp' => 13,
             'maxHP' => 19, 'status' => 'SLEEP', 'item' => 'ORANBERRY', 'types' => ['NORMAL'],
             'moves' => [{ 'id' => 'TACKLE', 'pp' => 3, 'maxPP' => 35 }] }
%w[19 19.1 20 20.1 21 21.1].each do |v|
  remove_global_constant(:PokeBattle_Battle)
  remove_global_constant(:Battle)
  klass = Class.new(battle_type)
  Object.const_set(v.start_with?('19') ? :PokeBattle_Battle : :Battle, klass)
  $Trainer, $player = v.start_with?('19') ? [actor, nil] : [nil, actor]
  version(v)
  load SCRIPT
  snap = snapshot
  check(snap['schemaVersion'], 1, v)
  check(snap['map'], { 'id' => 53, 'name' => 'Café' }, v)
  check(snap['party'], [expected], v)
  check(snap['encounters'].first, { 'species' => 'EEVEE', 'method' => 'Land', 'weight' => 20,
        'minLevel' => 2, 'maxLevel' => 3, 'seen' => true, 'caught' => false }, v)
  check(snap['encounters'][1]['maxLevel'], 7, v)
  check(snap['encounters'][2]['method'], 'OldRod', v)
  check(snap['battle'], nil, v)
  check(System.probe.call, nil, 'idle')
  battle = klass.new
  battle.battlers = battlers
  result = battle.pbStartBattle(:token) do
    live = snapshot.fetch('battle')
    check(live['allies'].first['types'], ['WATER'], v)
    check(live['opponents'].map { |foe| foe['index'] }, [1, 3], v)
    check(live['opponents'].first['hpPercent'], 19, v)
    check(live['opponents'].first['types'], %w[FIRE FLYING], v)
    check(live['opponents'].first['stages'], { 'DEFENSE' => 3 }, v)
    check(System.probe.call, nil, 'unchanged battle')
    :result
  end
  check(result, [:token, :result], 'game return value and passed block')
  check(snapshot['battle'], nil, 'battle ended')
end

# Count top-level serializations, including clear and changed samples.
telemetry = EmpoEssentialsTelemetry.singleton_class
telemetry.class_eval do
  alias_method :original_json_for_test, :json
  define_method(:json) do |obj|
    $encoded += 1 if obj.is_a?(Hash) && obj.key?('schemaVersion')
    original_json_for_test(obj)
  end
end
$encoded = 0
20.times { check(System.probe.call, nil, 'idle sample') }
check($encoded, 0, 'no idle serialization')
party_member.name.replace("é\u0000x")
check(snapshot['party'].first['nickname'], "é\u0000x", 'in-place nickname + NUL')
check($encoded, 1, 'encoded after mutation')
dex.caught = true
check(snapshot['encounters'].first['caught'], true, 'capture on same map')
table[:Land].first[0] = 25
check(snapshot['encounters'].first['weight'], 25, 'hot-edited encounter table')
$PokemonGlobal.encounter_version = 1
check(snapshot['encounters'], [], 'available empty versioned table')
$PokemonGlobal.encounter_version = 0
map.map_id = 54
check(snapshot['encounters'].first['species'], 'ONIX', 'map changed')
map.map_id = 999
check(snapshot['encounters'], nil, 'no encounter data')
map.map_id = 53
battle = Battle.new
battle.battlers = battlers
begin
  battle.pbStartBattle(:error) do
    check(snapshot['battle']['opponents'].length, 2, 'battle started')
    raise ArgumentError, 'preserve game exception'
  end
rescue ArgumentError => e
  check(e.message, 'preserve game exception', 'original error')
else
  raise 'game error swallowed'
end
check(snapshot['battle'], nil, 'exception clears battle')
$scene = Scene_Intro.new
blank = { 'schemaVersion' => 1, 'map' => nil, 'party' => [], 'encounters' => nil, 'battle' => nil }
check(snapshot, blank, 'title with stale globals')
check(System.probe.call, nil, 'unchanged title')
$scene = Object.new
check(snapshot['party'].size, 1, 'return to game')
$player = nil
check(snapshot, blank, 'no player')
$player = actor
broken = Object.new
def broken.species; raise 'missing game registry'; end
actor.party = [broken, party_member]
check(snapshot['party'].size, 1, 'broken party entry')
actor.party = [party_member]
def dex.seen?(_id); raise 'no dex'; end
check(snapshot['encounters'].first['seen'], nil, 'custom dex failure')

module PBSpecies; EEVEE = 133; end
module PBMoves; TACKLE = 33; end
module PBTypes; NORMAL = 0; end
module PBItems; ORANBERRY = 155; end
module PBStatuses; SLEEP = 1; end
GameData.send(:remove_const, :Species)
legacy_move = Struct.new(:id, :pp, :totalpp).new(33, 2, 35)
legacy = Struct.new(:species, :name, :hp, :totalhp, :level, :item, :moves, :status, :type1, :type2).
  new(133, 'Legacy', 8, 12, 4, 155, [legacy_move], 1, 0, 0)
$Trainer, $player = player_type.new([legacy], nil), nil
version('19.1')
load SCRIPT
mon = snapshot['party'].first
check(mon.values_at('species', 'item', 'status', 'types'), ['EEVEE', 'ORANBERRY', 'SLEEP', ['NORMAL']],
      'legacy enum names')
check(mon['moves'].first, { 'id' => 'TACKLE', 'pp' => 2, 'maxPP' => 35 }, 'legacy move')
legacy.status, legacy.item = 0, 0
check(snapshot['party'].first.values_at('status', 'item'), [nil, nil], 'legacy empty item/status')
legacy.species = 444_444
check(snapshot['party'], [], 'unknown legacy ID')

# First-launch corrupt/oversized data should leave the rest of the payload usable.
map.map_id = 55
registry[[55, 0]] = encounter.new({ :Land => [[100, :EEVEE, 1, 2]] * 257 })
$player = Object.new
legacy.species = 133
snap = snapshot
check(snap['party'].first['species'], 'EEVEE', 'legacy trainer with foreign $player')
check(snap['encounters'], nil, 'oversized table is unavailable without false rates')
remove_global_constant(:Battle)
Object.const_set(:Battle, Class.new(battle_type).freeze)
load SCRIPT
check(snapshot['party'].first['species'], 'EEVEE', 'frozen battle class retains party reporting')
check(Battle.ancestors.include?(EmpoEssentialsTelemetry::BattleLifetime), false, 'frozen class untouched')
legacy.name = "\xFF".dup.force_encoding('UTF-8')
check(snapshot['party'].first['nickname'], 'EEVEE', 'invalid save encoding is contained')

test_passed('Essentials telemetry', 145)
