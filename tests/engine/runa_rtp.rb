# An imported Runa configuration points at the old app's container.
# CI supplies that path as an overlay alongside a normal relative RTP.
unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('runa-rtp', 3)

EngineTest.test('a bundled XP runtime pack mounts at the virtual root') do
  EngineTest.owning(Bitmap.new('portable-rtp.png')) do |image|
    EngineTest.assert_equal(1, image.width, 'bundled RTP image')
  end
end

EngineTest.test('a separate relative RTP still mounts') do
  EngineTest.owning(Bitmap.new('lookup.bmp')) do |image|
    EngineTest.assert_equal(2, image.width, 'relative RTP image')
  end
end

EngineTest.test('the game can load its own assets') do
  EngineTest.owning(Bitmap.new('Graphics/Lookup/lookup.png')) do |image|
    EngineTest.assert_equal(1, image.width, 'game image')
  end
end

EngineTest.finish
exit
