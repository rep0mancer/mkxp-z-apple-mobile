#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Runs standalone and inside the embedded MRI regression host.
module System
  class << self
    attr_accessor :requests, :answer, :disabled, :pending
    def __game_translation_start(text)
      return nil if disabled
      requests << text
      1
    end
    def __game_translation_result(id)
      raise 'wrong request' unless id == 1
      if pending && pending > 0
        self.pending -= 1
        return nil
      end
      return answer unless answer == :dictionary
      dict = { 'Hello' => 'Hallo', 'Hola' => 'Hallo', 'Good morning!' => 'Guten Morgen!',
        'Buenos días!' => 'Guten Morgen!', 'Yes' => 'Ja', 'No' => 'Nein', 'Sí' => 'Ja',
        'uses' => 'setzt ein', 'Ready?' => 'Bereit?', 'Choose' => 'Wähle' }
      requests.last.split("\x1f", -1).map { |key| dict.fetch(key, 'UNEXPECTED') }.join("\x1f")
    end
  end
end
module Graphics
  class << self
    attr_accessor :test_frames
    def update
      self.test_frames += 1
    end
  end
end
def pbMessageDisplay(window, text, animate = true, command = nil, &block)
  window << text
  raise ArgumentError, 'from game' if window.size > 1
  [animate, command && command.call, block && block.call]
end
def pbShowCommands(window, choices = nil, cancel = 0, selected = 0)
  window << choices
  selected
end
def pbShowCommandsWithHelp(window, choices, help, cancel = 0, selected = 0)
  window << help
  pbShowCommands(window, choices, cancel, selected)
end

class Window_Selectable; end
class Window_Message < Window_Selectable
  def terminate_message; end
  def reset_window; end
  def update_cursor_rect; end
  def refresh
    source = $game_temp.message_text
    saved = source.dup
    source.slice!(0, source.size)
    saved
  end
end
class Game_Temp
  attr_accessor :message_text, :choice_start, :num_input_start
end
field_private = Object.private_method_defined?(:pbMessageDisplay)
script = ENV['EMPO_TRANSLATION_ADAPTER'] || File.expand_path('../scripts/postload/game_translation.rb', File.dirname(__FILE__))
eval(File.open(script, 'rb') { |f| f.read }, TOPLEVEL_BINDING, script)
def check(result, expected)
  raise "Expected #{expected.inspect}, got #{result.inspect}" unless result == expected
  $checked += 1
end
$checked = 0
Graphics.test_frames = 0
System.requests = []
System.answer = :dictionary
$game_temp = Game_Temp.new
$game_temp.choice_start = 1
$game_temp.num_input_start = 3
stock_buffer = "Hello\nYes\nNo\n"
$game_temp.message_text = stock_buffer
check(Window_Message.new.refresh, "Hallo\nJa\nNein\n")
check([$game_temp.message_text, $game_temp.choice_start, $game_temp.num_input_start], ['', 1, 3])
check(stock_buffer.empty?, true)

module Essentials; VERSION = '18.1'; end
module GameData; module Species; end; end
EmpoGameTranslation.install
window = []
pbMessageDisplay(window, 'Hello')
check(window, ['Hello'])
class PokeBattle_Scene
  attr_reader :shown
  def pbDisplayMessage(text, brief = false, &block)
    @shown = text
    [brief, block && block.call]
  end
  alias pbDisplay pbDisplayMessage
  def pbDisplayPausedMessage(text, &block)
    pbDisplayMessage(text, true, &block)
  end
  def pbShowCommands(text, labels, default)
    @shown = [text, labels]
    default
  end
end
$player = Struct.new(:party, :name).new([Struct.new(:name).new('Nala')], 'Andreas')
['19', '19.1', '20', '20.1', '21', '21.1'].each do |version|
  Essentials.send(:remove_const, :VERSION)
  Essentials.const_set(:VERSION, version)
  if version == '20'
    Object.const_set(:Battle, Module.new) unless defined?(Battle)
    Battle.const_set(:Scene, Class.new(PokeBattle_Scene))
  end
  EmpoGameTranslation.install
  EmpoGameTranslation.install
  source = "Hola Andreas!\\wt[12]\\PN\\c[1] <b>Good morning!</b>\n{1}%2$s\\ch[7,-1,Yes,No]".freeze
  window = []
  cb = proc { :command }
  System.pending = 2
  before = Graphics.test_frames
  check(pbMessageDisplay(window, source, false, cb) { :block }, [false, :command, :block])
  check(window, ["Hallo Andreas!\\wt[12]\\PN\\c[1] <b>Guten Morgen!</b>\n{1}%2$s\\ch[7,-1,Yes,No]"])
  check(Graphics.test_frames - before, 2)
  check(System.requests.last, "Hola\x1fGood morning!")
  check(Object.private_method_defined?(:pbMessageDisplay), field_private)
  labels = ['Sí'.freeze, 'No'.freeze, 'Sí'.freeze].freeze
  window = []
  n = System.requests.size
  check(pbShowCommandsWithHelp(window, labels, ['Hello','Hola','Hello'], -1, 2), 2)
  check(window, [['Hallo','Hallo','Hallo'], ['Ja','Nein','Ja']])
  check(System.requests.size - n, 1)
  check(labels, ['Sí','No','Sí'])
  scene = (version[0,2] == '19' ? PokeBattle_Scene : Battle::Scene).new
  check(scene.pbDisplay('Buenos días!', true) { 17 }, [true, 17])
  check(scene.shown, 'Guten Morgen!')
  n = System.requests.size
  check(scene.pbDisplayPausedMessage('Ready?') { 19 }, [true, 19])
  check(scene.shown, 'Bereit?')
  check(System.requests.size - n, 1)
  check(scene.pbShowCommands('Choose', labels, 1), 1)
  check(scene.shown, ['Wähle', ['Ja', 'Nein', 'Ja']])
end
$player.party << Struct.new(:name).new('Nidoran♀')
$player.party << Struct.new(:name).new('Flabébé')
window = []
pbMessageDisplay(window, 'Hola Nidoran♀! Flabébé!')
check(window, ['Hallo Nidoran♀! Flabébé!'])
check(System.requests.last, 'Hola')
System.answer = false
window = []
pbMessageDisplay(window, 'Hello')
check(window, ['Hello'])
['', "Hallo\x1fextra", '\\wt[200]', '<b>Hallo', "{1}Hallo", "%1$s", "[123]", "Hallo\x01"].each do |bad|
  System.answer = bad
  window = []
  pbMessageDisplay(window, 'Hello')
  check(window, ['Hello'])
end
System.answer = :dictionary
n = System.requests.size
["Hello\x1fNo", 'Hello \\c[12', 'x' * 16385].each do |bad|
  window = []
  pbMessageDisplay(window, bad)
  check(window, [bad])
end
check(n, System.requests.size)
System.disabled = true
window = []
pbMessageDisplay(window, 'Hello')
check(window, ['Hello'])
begin
  pbMessageDisplay(window, 'Hello')
  raise 'lost game exception'
rescue ArgumentError => e
  check(e.message, 'from game')
end
report = "TRANSLATION REGRESSION COMPLETE: #{$checked} assertions (Ruby #{RUBY_VERSION})"
defined?(msgbox) ? msgbox(report) : puts(report)
