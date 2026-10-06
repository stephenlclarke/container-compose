require "minitest/autorun"
require "tmpdir"
require "pathname"
require "fileutils"
require "digest"
class Formula
  def self.test; end
  def self.method_missing(*); end
  def self.respond_to_missing?(*); true; end
  attr_accessor :fixture_prefix
  def prefix; fixture_prefix; end
  def odie(message); raise message; end
end
load File.join(__dir__,"container-bazel.rb.in")
class SignedRestoreTest < Minitest::Test
  def setup
    @temporary=Dir.mktmpdir;@root=Pathname.new(@temporary).realpath
    @source=@root/"source";@keg=@root/"keg";FileUtils.mkdir_p(@source);FileUtils.mkdir_p(@keg/"libexec/bin")
    (@source/"signed").write("original signed payload bytes");(@keg/"libexec/bin/tool").write("Brew relocated bytes")
    @hash=Digest::SHA256.file(@source/"signed").hexdigest
    @formula=Container.new;@formula.fixture_prefix=@keg
  end
  def teardown;FileUtils.rm_rf(@temporary);end
  def files;[["signed","libexec/bin/tool",@hash]];end
  def test_exact_payload_is_restored_without_signing
    @formula.restore_signed_files(@source,files)
    assert_equal("original signed payload bytes",(@keg/"libexec/bin/tool").read)
    assert_equal(0o755,File.stat(@keg/"libexec/bin/tool").mode & 0o777)
  end
  def test_altered_resource_does_not_mutate_destination
    (@source/"signed").write("different")
    assert_raises(RuntimeError){@formula.restore_signed_files(@source,files)}
    assert_equal("Brew relocated bytes",(@keg/"libexec/bin/tool").read)
  end
  def test_symlink_destination_and_aliased_parent_reject
    File.unlink(@keg/"libexec/bin/tool");File.symlink(@source/"signed",@keg/"libexec/bin/tool")
    assert_raises(RuntimeError){@formula.restore_signed_files(@source,files)}
    assert_equal("original signed payload bytes",(@source/"signed").read)
  end
  def test_foreign_temporary_file_is_never_deleted
    temporary=@keg/"libexec/bin/.tool.signed-restore-#{Process.pid}";temporary.write("foreign")
    assert_raises(Errno::EEXIST){@formula.restore_signed_files(@source,files)}
    assert_equal("foreign",temporary.read)
  end
  def test_all_sources_are_preflighted_before_any_replacement
    list=files+[["missing","libexec/bin/tool",@hash]]
    assert_raises(RuntimeError){@formula.restore_signed_files(@source,list)}
    assert_equal("Brew relocated bytes",(@keg/"libexec/bin/tool").read)
  end
  def test_escape_destination_rejects_without_mutation
    assert_raises(RuntimeError){@formula.restore_signed_files(@source,[["signed","../foreign",@hash]])}
    refute((@root/"foreign").exist?)
  end
end
