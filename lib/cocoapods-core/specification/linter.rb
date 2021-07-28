require 'cocoapods-core/specification/linter/result'
require 'cocoapods-core/specification/linter/analyzer'

module Pod
  class Specification
    # The Linter check specifications for errors and warnings.
    #
    # It is designed not only to guarantee the formal functionality of a
    # specification, but also to support the maintenance of sources.
    #
    class Linter
      # @return [Specification] the specification to lint.
      #
      attr_reader :spec

      # @return [Pathname] the path of the `podspec` file where {#spec} is
      #         defined.
      #
      attr_reader :file

      attr_reader :results

      # @param  [Specification, Pathname, String] spec_or_path
      #         the Specification or the path of the `podspec` file to lint.
      #
      def initialize(spec_or_path)
        if spec_or_path.is_a?(Specification)
          @spec = spec_or_path
          @file = @spec.defined_in_file
        else
          @file = Pathname.new(spec_or_path)
          begin
            @spec = Specification.from_file(@file)
          rescue => e
            @spec = nil
            @raise_message = e.message
          end
        end
      end

      # Lints the specification adding a {Result} for any failed check to the
      # {#results} object.
      #
      # @return [Bool] whether the specification passed validation.
      #
      def lint
        @results = Results.new
        if spec
          validate_root_name
          check_required_attributes
          check_requires_arc_attribute
          run_root_validation_hooks
          perform_all_specs_analysis
        else
          results.add_error('spec', "The specification defined in `#{file}` "\
            "could not be loaded.\n\n#{@raise_message}")
        end
        results.empty?
      end

      #-----------------------------------------------------------------------#

      # !@group Lint results

      public

      # @return [Array<Result>] all the errors generated by the Linter.
      #
      def errors
        @errors ||= results.select { |r| r.type == :error }
      end

      # @return [Array<Result>] all the warnings generated by the Linter.
      #
      def warnings
        @warnings ||= results.select { |r| r.type == :warning }
      end

      #-----------------------------------------------------------------------#

      private

      # !@group Lint steps

      # Checks that the spec's root name matches the filename.
      #
      # @return [void]
      #
      def validate_root_name
        if spec.root.name && file
          acceptable_names = [
            spec.root.name + '.podspec',
            spec.root.name + '.podspec.json',
          ]
          names_match = acceptable_names.include?(file.basename.to_s)
          unless names_match
            results.add_error('name', 'The name of the spec should match the ' \
                              'name of the file.')
          end
        end
      end

      # Generates a warning if the requires_arc attribute has true or false string values.
      #
      # @return [void]
      #
      def check_requires_arc_attribute
        attribute = DSL.attributes.values.find { |attr| attr.name == :requires_arc }
        if attribute
          value = spec.send(attribute.name)
          if value == 'true' || value == 'false'
            results.add_warning('requires_arc', value + ' is considered to be the name of a file.')
          end
        end
      end

      # Checks that every required attribute has a value.
      #
      # @return [void]
      #
      def check_required_attributes
        attributes = DSL.attributes.values.select(&:required?)
        attributes.each do |attr|
          begin
            value = spec.send(attr.name)
            unless value && (!value.respond_to?(:empty?) || !value.empty?)
              if attr.name == :license
                results.add_warning('attributes', 'Missing required attribute ' \
                "`#{attr.name}`.")
              else
                results.add_error('attributes', 'Missing required attribute ' \
                 "`#{attr.name}`.")
              end
            end
          rescue => exception
            results.add_error('attributes', "Unable to parse attribute `#{attr.name}` due to error: #{exception}")
          end
        end
      end

      # Runs the validation hook for root only attributes.
      #
      # @return [void]
      #
      def run_root_validation_hooks
        attributes = DSL.attributes.values.select(&:root_only?)
        run_validation_hooks(attributes, spec)
      end

      # Run validations for multi-platform attributes activating.
      #
      # @return [void]
      #
      def perform_all_specs_analysis
        all_specs = [spec, *spec.recursive_subspecs]
        all_specs.each do |current_spec|
          current_spec.available_platforms.each do |platform|
            @consumer = Specification::Consumer.new(current_spec, platform)
            results.consumer = @consumer
            run_all_specs_validation_hooks
            analyzer = Analyzer.new(@consumer, results)
            results = analyzer.analyze
            @consumer = nil
            results.consumer = nil
          end
        end
      end

      # @return [Specification::Consumer] the current consumer.
      #
      attr_accessor :consumer

      # Runs the validation hook for the attributes that are not root only.
      #
      # @return [void]
      #
      def run_all_specs_validation_hooks
        attributes = DSL.attributes.values.reject(&:root_only?)
        run_validation_hooks(attributes, consumer)
      end

      # Runs the validation hook for each attribute.
      #
      # @note   Hooks are called only if there is a value for the attribute as
      #         required attributes are already checked by the
      #         {#check_required_attributes} step.
      #
      # @return [void]
      #
      def run_validation_hooks(attributes, target)
        attributes.each do |attr|
          validation_hook = "_validate_#{attr.name}"
          next unless respond_to?(validation_hook, true)
          begin
            value = target.send(attr.name)
            next unless value
            send(validation_hook, value)
          rescue => e
            results.add_error(attr.name, "Unable to validate due to exception: #{e}")
          end
        end
      end

      #-----------------------------------------------------------------------#

      private

      # Performs validations related to the `name` attribute.
      #
      def _validate_name(name)
        if name =~ %r{/}
          results.add_error('name', 'The name of a spec should not contain ' \
                         'a slash.')
        end

        if name =~ /\s/
          results.add_error('name', 'The name of a spec should not contain ' \
                         'whitespace.')
        end

        if name[0, 1] == '.'
          results.add_error('name', 'The name of a spec should not begin' \
          ' with a period.')
        end
      end

      # @!group Root spec validation helpers

      # Performs validations related to the `authors` attribute.
      #
      def _validate_authors(a)
        if a.is_a? Hash
          if a == { 'YOUR NAME HERE' => 'YOUR EMAIL HERE' }
            results.add_error('authors', 'The authors have not been updated ' \
              'from default')
          end
        end
      end

      # Performs validations related to the `version` attribute.
      #
      def _validate_version(v)
        if v.to_s.empty?
          results.add_error('version', 'A version is required.')
        end
      end

      # Performs validations related to the `module_name` attribute.
      #
      def _validate_module_name(m)
        unless m.nil? || m =~ /^[a-z_][0-9a-z_]*$/i
          results.add_error('module_name', 'The module name of a spec' \
            ' should be a valid C99 identifier.')
        end
      end

      # Performs validations related to the `summary` attribute.
      #
      def _validate_summary(s)
        if s.length > 140
          results.add_warning('summary', 'The summary should be a short ' \
            'version of `description` (max 140 characters).')
        end
        if s =~ /A short description of/
          results.add_warning('summary', 'The summary is not meaningful.')
        end
      end

      # Performs validations related to the `description` attribute.
      #
      def _validate_description(d)
        if d == spec.summary
          results.add_warning('description', 'The description is equal to' \
           ' the summary.')
        end

        if d.strip.empty?
          results.add_error('description', 'The description is empty.')
        elsif spec.summary && d.length < spec.summary.length
          results.add_warning('description', 'The description is shorter ' \
          'than the summary.')
        end
      end

      # Performs validations related to the `homepage` attribute.
      #
      def _validate_homepage(h)
        return unless h.is_a?(String)
        if h =~ %r{http://EXAMPLE}
          results.add_warning('homepage', 'The homepage has not been updated' \
           ' from default')
        end
      end

      # Performs validations related to the `frameworks` attribute.
      #
      def _validate_frameworks(frameworks)
        if frameworks_invalid?(frameworks)
          results.add_error('frameworks', 'A framework should only be' \
          ' specified by its name')
        end
      end

      # Performs validations related to the `weak frameworks` attribute.
      #
      def _validate_weak_frameworks(frameworks)
        if frameworks_invalid?(frameworks)
          results.add_error('weak_frameworks', 'A weak framework should only be' \
          ' specified by its name')
        end
      end

      # Performs validations related to the `libraries` attribute.
      #
      def _validate_libraries(libs)
        libs.each do |lib|
          lib = lib.downcase
          if lib.end_with?('.a') || lib.end_with?('.dylib')
            results.add_error('libraries', 'Libraries should not include the' \
            ' extension ' \
            "(`#{lib}`)")
          end

          if lib.start_with?('lib')
            results.add_error('libraries', 'Libraries should omit the `lib`' \
            ' prefix ' \
            " (`#{lib}`)")
          end

          if lib.include?(',')
            results.add_error('libraries', 'Libraries should not include comas ' \
            "(`#{lib}`)")
          end
        end
      end

      # Performs validations related to the `vendored_libraries` attribute.
      #
      # @param [Array<String>] vendored_libraries the values specified in the `vendored_libraries` attribute
      #
      def _validate_vendored_libraries(vendored_libraries)
        vendored_libraries.each do |lib|
          lib_name = lib.downcase
          unless lib_name.end_with?('.a') && lib_name.start_with?('lib')
            results.add_warning('vendored_libraries', "`#{File.basename(lib)}` does not match the expected static library name format `lib[name].a`")
          end
        end
      end

      # Performs validations related to the `license` attribute.
      #
      def _validate_license(l)
        type = l[:type]
        file = l[:file]
        if type.nil?
          results.add_warning('license', 'Missing license type.')
        end
        if type && type.delete(' ').delete("\n").empty?
          results.add_warning('license', 'Invalid license type.')
        end
        if type && type =~ /\(example\)/
          results.add_error('license', 'Sample license type.')
        end
        if file && Pathname.new(file).extname !~ /^(\.(txt|md|markdown|))?$/i
          results.add_error('license', 'Invalid file type')
        end
      end

      # Performs validations related to the `source` attribute.
      #
      def _validate_source(s)
        return unless s.is_a?(Hash)
        if git = s[:git]
          tag, commit = s.values_at(:tag, :commit)
          version = spec.version.to_s

          if git =~ %r{http://EXAMPLE}
            results.add_error('source', 'The Git source still contains the ' \
            'example URL.')
          end
          if commit && commit.downcase =~ /head/
            results.add_error('source', 'The commit of a Git source cannot be' \
            ' `HEAD`.')
          end
          if tag && !tag.to_s.include?(version)
            results.add_warning('source', 'The version should be included in' \
             ' the Git tag.')
          end
          if tag.nil?
            results.add_warning('source', 'Git sources should specify a tag.', true)
          end
        end

        perform_github_source_checks(s)
        check_git_ssh_source(s)
      end

      # Performs validations related to the `deprecated_in_favor_of` attribute.
      #
      def _validate_deprecated_in_favor_of(d)
        if spec.root.name == Specification.root_name(d)
          results.add_error('deprecated_in_favor_of', 'a spec cannot be ' \
            'deprecated in favor of itself')
        end
      end

      # Performs validations related to the `test_type` attribute.
      #
      def _validate_test_type(t)
        supported_test_types = Specification::DSL::SUPPORTED_TEST_TYPES.map(&:to_s)
        unless supported_test_types.include?(t.to_s)
          results.add_error('test_type', "The test type `#{t}` is not supported. " \
            "Supported test type values are #{supported_test_types}.")
        end
      end

      def _validate_app_host_name(n)
        unless consumer.requires_app_host?
          results.add_error('app_host_name', '`requires_app_host` must be set to ' \
            '`true` when `app_host_name` is specified.')
        end

        unless consumer.dependencies.map(&:name).include?(n)
          results.add_error('app_host_name', "The app host name (#{n}) specified by `#{consumer.spec.name}` could " \
            'not be found. You must explicitly declare a dependency on that app spec.')
        end
      end

      # Performs validations related to the `script_phases` attribute.
      #
      def _validate_script_phases(s)
        s.each do |script_phase|
          keys = script_phase.keys
          unrecognized_keys = keys - Specification::ALL_SCRIPT_PHASE_KEYS
          unless unrecognized_keys.empty?
            results.add_error('script_phases', "Unrecognized option(s) `#{unrecognized_keys.join(', ')}` in script phase `#{script_phase[:name]}`. " \
              "Available options are `#{Specification::ALL_SCRIPT_PHASE_KEYS.join(', ')}`.")
          end
          missing_required_keys = Specification::SCRIPT_PHASE_REQUIRED_KEYS - keys
          unless missing_required_keys.empty?
            results.add_error('script_phases', "Missing required shell script phase options `#{missing_required_keys.join(', ')}` in script phase `#{script_phase[:name]}`.")
          end
          unless Specification::EXECUTION_POSITION_KEYS.include?(script_phase[:execution_position])
            results.add_error('script_phases', "Invalid execution position value `#{script_phase[:execution_position]}` in shell script `#{script_phase[:name]}`. " \
            "Available options are `#{Specification::EXECUTION_POSITION_KEYS.join(', ')}`.")
          end
        end
      end

      # Performs validation related to the `scheme` attribute.
      #
      def _validate_scheme(s)
        unless s.empty?
          if consumer.spec.subspec? && consumer.spec.library_specification?
            results.add_error('scheme', 'Scheme configuration is not currently supported for subspecs.')
            return
          end
          if s.key?(:launch_arguments) && !s[:launch_arguments].is_a?(Array)
            results.add_error('scheme', 'Expected an array for key `launch_arguments`.')
          end
          if s.key?(:environment_variables) && !s[:environment_variables].is_a?(Hash)
            results.add_error('scheme', 'Expected a hash for key `environment_variables`.')
          end
          if s.key?(:code_coverage) && ![true, false].include?(s[:code_coverage])
            results.add_error('scheme', 'Expected a boolean for key `code_coverage`.')
          end
        end
      end

      # Performs validations related to github sources.
      #
      def perform_github_source_checks(s)
        require 'uri'

        if git = s[:git]
          return unless git =~ /^#{URI.regexp}$/
          git_uri = URI.parse(git)
          if git_uri.host
            perform_github_uri_checks(git, git_uri) if git_uri.host.end_with?('github.com')
          end
        end
      end

      def perform_github_uri_checks(git, git_uri)
        if git_uri.host.start_with?('www.')
          results.add_warning('github_sources', 'Github repositories should ' \
            'not use `www` in their URL.')
        end
        unless git.end_with?('.git')
          results.add_warning('github_sources', 'Github repositories ' \
            'should end in `.git`.')
        end
        unless git_uri.scheme == 'https'
          results.add_warning('github_sources', 'Github repositories ' \
            'should use an `https` link.', true)
        end
      end

      # Performs validations related to SSH sources
      #
      def check_git_ssh_source(s)
        if git = s[:git]
          if git =~ %r{\w+\@(\w|\.)+\:(/\w+)*}
            results.add_warning('source', 'Git SSH URLs will NOT work for ' \
              'people behind firewalls configured to only allow HTTP, ' \
              'therefore HTTPS is preferred.', true)
          end
        end
      end

      # Performs validations related to the `social_media_url` attribute.
      #
      def _validate_social_media_url(s)
        if s =~ %r{https://twitter.com/EXAMPLE}
          results.add_warning('social_media_url', 'The social media URL has ' \
            'not been updated from the default.')
        end
      end

      # Performs validations related to the `readme` attribute.
      #
      def _validate_readme(s)
        if s =~ %r{https://www.example.com/README}
          results.add_warning('readme', 'The readme has ' \
            'not been updated from the default.')
        end
      end

      # Performs validations related to the `changelog` attribute.
      #
      def _validate_changelog(s)
        if s =~ %r{https://www.example.com/CHANGELOG}
          results.add_warning('changelog', 'The changelog has ' \
            'not been updated from the default.')
        end
      end

      # @param [Hash,Object] value
      #
      def _validate_info_plist(value)
        return if value.empty?
        if consumer.spec.subspec? && consumer.spec.library_specification?
          results.add_error('info_plist', 'Info.plist configuration is not currently supported for subspecs.')
        end
      end

      #-----------------------------------------------------------------------#

      # @!group All specs validation helpers

      private

      # Performs validations related to the `compiler_flags` attribute.
      #
      def _validate_compiler_flags(flags)
        if flags.join(' ').split(' ').any? { |flag| flag.start_with?('-Wno') }
          results.add_warning('compiler_flags', 'Warnings must not be disabled' \
          '(`-Wno compiler` flags).')
        end
      end

      # Returns whether the frameworks are valid
      #
      # @param frameworks [Array<String>]
      # The frameworks to be validated
      #
      # @return [Boolean] true if a framework contains any
      # non-alphanumeric character or includes an extension.
      #
      def frameworks_invalid?(frameworks)
        frameworks.any? do |framework|
          framework_regex = /[^\w\-\+]/
          framework =~ framework_regex
        end
      end
    end
  end
end
