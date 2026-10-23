#!/usr/bin/env ruby
# frozen_string_literal: true

# Decides whether a Renovate PR may be auto-merged, from the DIFF ALONE.
#
#   renovate-automerge-check.rb <base_sha> <head_sha> <tier>
#
# <tier> is the renovate/<tier> label Renovate applied (see
# .github/renovate.json5). The label only says what the PR CLAIMS to be; this
# script re-derives the update class from the files and refuses anything that
# does not match, so a wrong or tampered label can never widen what merges.
#
# Eligible tiers and what they allow:
#   npm-patch  — direct npm deps change only within the same major.minor
#   npm-minor  — direct npm deps change within the same major, and every
#                minor bump starts from >= 1.0.0
#   go-patch / go-minor — same rules for direct go.mod requires
# Common rules: only manifest/lock files may change, nothing under /upstream/,
# no added or removed direct dependencies, no prerelease/pseudo versions, and
# every non-dependency part of each manifest must be byte-for-byte identical.
#
# Reads git objects only (never executes PR content). Prints the reasons and a
# final "eligible=true|false" line; always exits 0 unless invoked wrongly.

require 'json'
require 'open3'
require 'yaml'

TIERS = {
  'npm-patch' => { ecosystem: :npm, max: :patch },
  'npm-minor' => { ecosystem: :npm, max: :minor },
  'go-patch' => { ecosystem: :go, max: :patch },
  'go-minor' => { ecosystem: :go, max: :minor },
}.freeze

NPM_FILE = %r{(\A|/)(package\.json|pnpm-lock\.yaml)\z}.freeze
GO_FILE = %r{(\A|/)go\.(mod|sum)\z}.freeze
NPM_DEP_SECTIONS = %w[dependencies devDependencies optionalDependencies peerDependencies].freeze
LOCK_DEP_SECTIONS = %w[dependencies devDependencies optionalDependencies].freeze
STABLE_VERSION = /\A(\d+)\.(\d+)\.(\d+)\z/.freeze

class Ineligible < StandardError; end

def git(*args)
  out, status = Open3.capture2('git', *args)
  raise Ineligible, "git #{args.join(' ')} failed" unless status.success?

  out
end

# File content at a revision, or nil when the file does not exist there.
def blob(rev, path)
  out, status = Open3.capture2('git', 'show', "#{rev}:#{path}")
  status.success? ? out : nil
end

# [major, minor, patch] for a stable release, nil for anything else
# (prereleases, Go pseudo-versions, +incompatible, link:, ranges, ...).
def stable(version)
  m = STABLE_VERSION.match(version.to_s.sub(/\Av/, ''))
  m && m.captures.map(&:to_i)
end

# :patch or :minor for an allowed change, raising for anything else.
def classify(name, from, to)
  old = stable(from)
  new = stable(to)
  raise Ineligible, "#{name}: #{from} -> #{to} is not a stable-release change" unless old && new
  raise Ineligible, "#{name}: #{from} -> #{to} is a downgrade" if (new <=> old) != 1
  raise Ineligible, "#{name}: #{from} -> #{to} is a major update" if new[0] != old[0]
  return :patch if new[1] == old[1]
  raise Ineligible, "#{name}: #{from} -> #{to} is a minor update of a pre-1.0 package" if old[0].zero?

  :minor
end

def check_changes(changes, max)
  raise Ineligible, 'no direct dependency changed' if changes.empty?

  changes.each do |(name, from, to)|
    kind = classify(name, from, to)
    raise Ineligible, "#{name}: #{from} -> #{to} is a minor update in a patch tier" if kind == :minor && max == :patch

    puts "ok: #{name} #{from} -> #{to} (#{kind})"
  end
end

# ── npm ──────────────────────────────────────────────────────────────────

# { "importer|section|dep" => version } for direct deps in a pnpm v9 lockfile.
def lock_direct_deps(text)
  lock = YAML.safe_load(text) || {}
  raise Ineligible, "unsupported lockfileVersion #{lock['lockfileVersion']}" unless lock['lockfileVersion'].to_s.start_with?('9')

  deps = {}
  (lock['importers'] || {}).each do |importer, sections|
    LOCK_DEP_SECTIONS.each do |section|
      (sections[section] || {}).each do |dep, info|
        # strip the peer-dependency suffix: 5.0.1(react@18.3.1) -> 5.0.1
        deps["#{importer}|#{section}|#{dep}"] = info['version'].to_s.split('(', 2).first
      end
    end
  end
  [lock, deps]
end

def check_npm(base, head, files, max)
  changes = []
  if files.include?('pnpm-lock.yaml')
    base_lock, before = lock_direct_deps(blob(base, 'pnpm-lock.yaml').to_s)
    head_lock, after = lock_direct_deps(blob(head, 'pnpm-lock.yaml').to_s)
    %w[lockfileVersion settings overrides].each do |key|
      raise Ineligible, "pnpm-lock.yaml: '#{key}' changed" if base_lock[key] != head_lock[key]
    end
    added = after.keys - before.keys
    removed = before.keys - after.keys
    raise Ineligible, "direct dependencies added: #{added.join(', ')}" unless added.empty?
    raise Ineligible, "direct dependencies removed: #{removed.join(', ')}" unless removed.empty?

    before.each do |key, from|
      to = after[key]
      changes << [key.split('|').last, from, to] if from != to
    end
  end
  changes.uniq!
  changed_names = changes.map(&:first)

  (files - ['pnpm-lock.yaml']).each do |path|
    old = JSON.parse(blob(base, path) || raise(Ineligible, "#{path} was added"))
    new = JSON.parse(blob(head, path) || raise(Ineligible, "#{path} was deleted"))
    (old.keys | new.keys).each do |key|
      next if NPM_DEP_SECTIONS.include?(key)
      raise Ineligible, "#{path}: '#{key}' changed" if old[key] != new[key]
    end
    NPM_DEP_SECTIONS.each do |section|
      o = old[section] || {}
      n = new[section] || {}
      raise Ineligible, "#{path}: #{section} entries added/removed" if o.keys.sort != n.keys.sort

      o.each do |dep, spec|
        next if n[dep] == spec
        # A specifier change must belong to a dependency whose resolved
        # version was checked above.
        raise Ineligible, "#{path}: #{dep} specifier changed without a lockfile change" unless changed_names.include?(dep)
      end
    end
  end

  check_changes(changes, max)
end

# ── go ───────────────────────────────────────────────────────────────────

REQUIRE_LINE = /\A\s*(?:require\s+)?(\S+)\s+(v\S+)(\s*\/\/\s*indirect)?\s*\z/.freeze

# [{ module => [version, indirect?] }, other non-require lines]
def parse_go_mod(text)
  requires = {}
  other = []
  in_require = false
  text.each_line do |raw|
    line = raw.sub(%r{\s*//(?!\s*indirect).*}, '').rstrip
    next if line.strip.empty?

    if line =~ /\Arequire\s*\(\s*\z/
      in_require = true
    elsif in_require && line.strip == ')'
      in_require = false
    elsif (in_require || line.start_with?('require ')) && (m = REQUIRE_LINE.match(line))
      requires[m[1]] = [m[2], !m[3].nil?]
    else
      other << line.strip
    end
  end
  [requires, other]
end

def check_go(base, head, files, max)
  changes = []
  files.grep(/go\.mod\z/).each do |path|
    old_req, old_other = parse_go_mod(blob(base, path) || raise(Ineligible, "#{path} was added"))
    new_req, new_other = parse_go_mod(blob(head, path) || raise(Ineligible, "#{path} was deleted"))
    raise Ineligible, "#{path}: non-require content changed (go/toolchain/replace/...)" if old_other != new_other

    # `go mod tidy` legitimately adds, drops, and re-classifies `// indirect`
    # requires (e.g. testify 1.12 no longer pulls in gopkg.in/yaml.v3). Their
    # versions are fixed by go.sum and the direct requires, so they are not
    # checked. A DIRECT require is different: it is code the module imports,
    # so a module may become direct only if it was already required.
    old_direct = old_req.reject { |_, (_, indirect)| indirect }
    new_direct = new_req.reject { |_, (_, indirect)| indirect }
    gone = old_direct.keys - new_req.keys
    raise Ineligible, "#{path}: direct requires removed: #{gone.join(', ')}" unless gone.empty?

    added = new_direct.keys - old_req.keys
    raise Ineligible, "#{path}: direct requires added: #{added.join(', ')}" unless added.empty?

    (old_direct.keys | new_direct.keys).each do |mod|
      from = old_req[mod][0]
      to = new_req[mod][0]
      changes << [mod, from, to] if from != to
    end
  end
  go_sums = files.grep(/go\.sum\z/)
  orphans = go_sums.reject { |sum| files.include?(sum.sub(/go\.sum\z/, 'go.mod')) }
  # A go.sum may legitimately change alone only when its go.mod is untouched
  # because nothing direct moved; that is not a dependency update.
  raise Ineligible, "go.sum changed without its go.mod: #{orphans.join(', ')}" unless orphans.empty?

  check_changes(changes.uniq, max)
end

# ── main ─────────────────────────────────────────────────────────────────

def main(base, head, tier)
  rule = TIERS[tier] or raise Ineligible, "tier '#{tier}' is not auto-merge eligible"
  merge_base = git('merge-base', base, head).strip
  files = git('diff', '--name-only', merge_base, head).split("\n")
  raise Ineligible, 'empty diff' if files.empty?

  upstream = files.grep(%r{(\A|/)upstream/})
  raise Ineligible, "touches upstream-synced files: #{upstream.join(', ')}" unless upstream.empty?

  pattern = rule[:ecosystem] == :npm ? NPM_FILE : GO_FILE
  foreign = files.grep_v(pattern)
  raise Ineligible, "files outside #{rule[:ecosystem]} manifests: #{foreign.join(', ')}" unless foreign.empty?

  puts "tier=#{tier} files=#{files.size} merge_base=#{merge_base[0, 10]}"
  if rule[:ecosystem] == :npm
    check_npm(merge_base, head, files, rule[:max])
  else
    check_go(merge_base, head, files, rule[:max])
  end
  puts 'eligible=true'
rescue Ineligible, JSON::ParserError, Psych::Exception => e
  puts "not eligible: #{e.message}"
  puts 'eligible=false'
end

abort "usage: #{$PROGRAM_NAME} <base_sha> <head_sha> <tier>" unless ARGV.size == 3
main(*ARGV)
