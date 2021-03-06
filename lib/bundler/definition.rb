require "digest/sha1"

module Bundler
  class Definition
    attr_reader :dependencies, :platforms

    def self.build(gemfile, lockfile, unlock)
      unlock ||= {}
      gemfile = Pathname.new(gemfile).expand_path

      unless gemfile.file?
        raise GemfileNotFound, "#{gemfile} not found"
      end

      # TODO: move this back into DSL
      builder = Dsl.new
      builder.instance_eval(File.read(gemfile.to_s), gemfile.to_s, 1)
      builder.to_definition(lockfile, unlock)
    end

=begin
    How does the new system work?
    ===
    * Load information from Gemfile and Lockfile
    * Invalidate stale locked specs
      * All specs from stale source are stale
      * All specs that are reachable only through a stale
        dependency are stale.
    * If all fresh dependencies are satisfied by the locked
      specs, then we can try to resolve locally.
=end

    def initialize(lockfile, dependencies, sources, unlock)
      @dependencies, @sources, @unlock = dependencies, sources, unlock
      @specs = nil
      @unlock[:gems] ||= []
      @unlock[:sources] ||= []

      if lockfile && File.exists?(lockfile)
        locked = LockfileParser.new(File.read(lockfile))
        @platforms      = locked.platforms
        @locked_deps    = locked.dependencies
        @last_resolve   = SpecSet.new(locked.specs)
        @locked_sources = locked.sources
      else
        @platforms      = []
        @locked_deps    = []
        @last_resolve   = SpecSet.new([])
        @locked_sources = []
      end

      current_platform = Gem.platforms.map { |p| p.to_generic }.compact.last
      @platforms |= [current_platform]

      converge
    end

    def resolve_remotely!
      raise "Specs already loaded" if @specs
      @sources.each { |s| s.remote! }
      specs
    end

    def specs
      @specs ||= resolve.materialize(requested_dependencies)
    end

    def missing_specs
      missing = []
      resolve.materialize(requested_dependencies, missing)
      missing
    end

    def requested_specs
      @requested_specs ||= begin
        groups = self.groups - Bundler.settings.without
        groups.map! { |g| g.to_sym }
        specs_for(groups)
      end
    end

    def current_dependencies
      dependencies.reject { |d| !d.should_include? }
    end

    def specs_for(groups)
      deps = dependencies.select { |d| (d.groups & groups).any? }
      deps.delete_if { |d| !d.should_include? }
      specs.for(expand_dependencies(deps))
    end

    def resolve
      @resolve ||= begin
        if @last_resolve.valid_for?(expanded_dependencies)
          @last_resolve
        else
          source_requirements = {}
          dependencies.each do |dep|
            next unless dep.source
            source_requirements[dep.name] = dep.source.specs
          end

          # Run a resolve against the locally available gems
          Resolver.resolve(expanded_dependencies, index, source_requirements, @last_resolve)
        end
      end
    end

    def index
      @index ||= Index.build do |idx|
        @sources.each do |s|
          idx.use s.specs
        end
      end
    end

    def no_sources?
      @sources.length == 1 && @sources.first.remotes.empty?
    end

    def groups
      dependencies.map { |d| d.groups }.flatten.uniq
    end

    def to_lock
      out = ""

      sorted_sources.each do |source|
        # Add the source header
        out << source.to_lock
        # Find all specs for this source
        resolve.
          select  { |s| s.source == source }.
          sort_by { |s| [s.name, s.platform.to_s == 'ruby' ? "\0" : s.platform.to_s] }.
          each do |spec|
            out << spec.to_lock
        end
        out << "\n"
      end

      out << "PLATFORMS\n"

      platforms.map { |p| p.to_s }.sort.each do |p|
        out << "  #{p}\n"
      end

      out << "\n"
      out << "DEPENDENCIES\n"

      dependencies.
        sort_by { |d| d.name }.
        each do |dep|
          out << dep.to_lock
      end

      out
    end

  private

    def converge
      converge_sources
      converge_dependencies
      converge_locked_specs
    end

    def converge_sources
      @sources = (@locked_sources & @sources) | @sources
      @sources.each do |source|
        source.unlock! if source.respond_to?(:unlock!) && @unlock[:sources].include?(source.name)
      end
    end

    def converge_dependencies
      (@dependencies + @locked_deps).each do |dep|
        if dep.source
          source = @sources.find { |s| dep.source == s }
          raise "Something went wrong, there is no matching source" unless source
          dep.source = source
        end
      end
    end

    def converge_locked_specs
      deps = []

      @dependencies.each do |dep|
        if in_locked_deps?(dep) || satisfies_locked_spec?(dep)
          deps << dep
        end
      end

      converged = []
      @last_resolve.each do |s|
        s.source = @sources.find { |src| s.source == src }

        next if s.source.nil? || @unlock[:sources].include?(s.name)

        converged << s
      end

      resolve = SpecSet.new(converged)
      resolve = resolve.for(expand_dependencies(deps), @unlock[:gems])
      @last_resolve.select!(resolve.names)
    end

    def in_locked_deps?(dep)
      @locked_deps.any? do |d|
        dep == d && dep.source == d.source
      end
    end

    def satisfies_locked_spec?(dep)
      @last_resolve.any? { |s| s.satisfies?(dep) }
    end

    def expanded_dependencies
      @expanded_dependencies ||= expand_dependencies(dependencies)
    end

    def expand_dependencies(dependencies)
      deps = []
      dependencies.each do |dep|
        dep.gem_platforms(@platforms).each do |p|
          deps << DepProxy.new(dep, p)
        end
      end
      deps
    end

    def sorted_sources
      @sources.sort_by do |s|
        # Place GEM at the top
        [ s.is_a?(Source::Rubygems) ? 1 : 0, s.to_s ]
      end
    end

    def requested_dependencies
      groups = self.groups - Bundler.settings.without
      groups.map! { |g| g.to_sym }
      dependencies.reject { |d| !d.should_include? || (d.groups & groups).empty? }
    end
  end
end
