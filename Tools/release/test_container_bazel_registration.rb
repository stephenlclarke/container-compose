# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
require "minitest/autorun"
require "tmpdir"
require "pathname"
require "fileutils"
class Formula
  def self.test; end
  def self.method_missing(*); end
  def self.respond_to_missing?(*); true; end
  attr_accessor :fixture_prefix
  def prefix; fixture_prefix; end
  def ln_s(source,target); File.symlink(source,target); end
  def odie(message); raise message; end
end
load File.join(__dir__, "container-bazel.rb.in")
class RegistrationTest < Minitest::Test
  def setup
    @temporary=Dir.mktmpdir;@root=Pathname.new(@temporary).realpath
    Object.send(:remove_const,:HOMEBREW_PREFIX) if Object.const_defined?(:HOMEBREW_PREFIX)
    Object.send(:remove_const,:HOMEBREW_CELLAR) if Object.const_defined?(:HOMEBREW_CELLAR)
    Object.const_set(:HOMEBREW_PREFIX,@root);Object.const_set(:HOMEBREW_CELLAR,@root/"Cellar")
    @runtime=@root/"Cellar/container/0.16.0";@plugin=@root/"Cellar/container-compose/0.16.0/libexec/container-plugins/compose"
    FileUtils.mkdir_p(@runtime/"libexec");FileUtils.mkdir_p(@plugin);FileUtils.mkdir_p(@root/"opt")
    File.symlink(@plugin.parent.parent.parent,@root/"opt/container-compose")
    @formula=Container.new;@formula.fixture_prefix=@runtime
    @link=@runtime/"libexec/container-plugins/compose"
  end
  def teardown;FileUtils.rm_rf(@temporary);end
  def test_registration_is_owned_and_idempotent
    @formula.post_install;assert_equal(@root/"opt/container-compose/libexec/container-plugins/compose",@link.readlink)
    @formula.post_install;assert(@link.symlink?)
  end
  def test_foreign_file_is_preserved
    FileUtils.mkdir_p(@link.parent);@link.write("foreign")
    assert_raises(RuntimeError){@formula.post_install};assert_equal("foreign",@link.read)
  end
  def test_foreign_directory_is_preserved
    FileUtils.mkdir_p(@link);(@link/"data").write("foreign")
    assert_raises(RuntimeError){@formula.post_install};assert_equal("foreign",(@link/"data").read)
  end
  def test_foreign_link_is_preserved
    FileUtils.mkdir_p(@link.parent);File.symlink(@root/"foreign",@link)
    assert_raises(RuntimeError){@formula.post_install};assert_equal(@root/"foreign",@link.readlink)
  end
  def test_aliased_destination_parent_is_rejected
    foreign=@root/"foreign";FileUtils.mkdir_p(foreign);File.symlink(foreign,@link.parent)
    assert_raises(RuntimeError){@formula.post_install};refute((foreign/"compose").exist?)
  end
end
