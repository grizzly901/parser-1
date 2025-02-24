# frozen_string_literal: true

module ParseHelper
  include AST::Sexp

  require 'parser/all'
  require 'parser/macruby'
  require 'parser/rubymotion'

  ALL_VERSIONS = %w(1.8 1.9 2.0 2.1 2.2 2.3 2.4 2.5 2.6 2.7 3.0 3.1 3.2 3.3 mac ios)

  def setup
    @diagnostics = []

    super if defined?(super)
  end

  def parser_for_ruby_version(version)
    case version
    when '1.8' then parser = Parser::Ruby18.new
    when '1.9' then parser = Parser::Ruby19.new
    when '2.0' then parser = Parser::Ruby20.new
    when '2.1' then parser = Parser::Ruby21.new
    when '2.2' then parser = Parser::Ruby22.new
    when '2.3' then parser = Parser::Ruby23.new
    when '2.4' then parser = Parser::Ruby24.new
    when '2.5' then parser = Parser::Ruby25.new
    when '2.6' then parser = Parser::Ruby26.new
    when '2.7' then parser = Parser::Ruby27.new
    when '3.0' then parser = Parser::Ruby30.new
    when '3.1' then parser = Parser::Ruby31.new
    when '3.2' then parser = Parser::Ruby32.new
    when '3.3' then parser = Parser::Ruby33.new
    when 'mac' then parser = Parser::MacRuby.new
    when 'ios' then parser = Parser::RubyMotion.new
    else raise "Unrecognized Ruby version #{version}"
    end

    parser.diagnostics.consumer = lambda do |diagnostic|
      @diagnostics << diagnostic
    end

    parser
  end

  def with_versions(versions)
    (versions & ALL_VERSIONS).each do |version|
      @diagnostics.clear

      parser = parser_for_ruby_version(version)
      yield version, parser
    end
  end

  def assert_source_range(expect_range, range, version, what)
    if expect_range == nil
      # Avoid "Use assert_nil if expecting nil from .... This will fail in Minitest 6.""
      assert_nil range,
                   "(#{version}) range of #{what}"
    else
      assert range.is_a?(Parser::Source::Range),
             "(#{version}) #{range.inspect}.is_a?(Source::Range) for #{what}"
      assert_equal expect_range, range.to_range,
                   "(#{version}) range of #{what}"
    end
  end

  # Use like this:
  # ~~~
  # assert_parses(
  #   s(:send, s(:lit, 10), :+, s(:lit, 20))
  #   %q{10 + 20},
  #   %q{~~~~~~~ expression
  #     |   ^ operator
  #     |     ~~ expression (lit)
  #     },
  #     %w(1.8 1.9) # optional
  # )
  # ~~~
  def assert_parses(ast, code, source_maps='', versions=ALL_VERSIONS)
    with_versions(versions) do |version, parser|
      try_parsing(ast, code, parser, source_maps, version)
    end

    # Also try parsing with lexer set to use UTF-32LE internally
    with_versions(versions) do |version, parser|
      parser.instance_eval { @lexer.force_utf32 = true }
      try_parsing(ast, code, parser, source_maps, version)
    end

    # Also check that it doesn't throw anything
    # except (possibly) Parser::SyntaxError on other versions of Ruby
    with_versions(ALL_VERSIONS - versions) do |version, parser|
      begin
        source_file = Parser::Source::Buffer.new('(assert_older_rubies)', source: code)
        parser.parse(source_file)
      rescue Parser::SyntaxError
        # ok
      rescue StandardError
        # unacceptable
        raise
      else
        # No error means that `code` is valid for `version`, but has a different meaning.
        # Sometimes Ruby has breaking changes (like numparams)
        # that re-use constructions from previous versions.
      end
    end
  end

  def try_parsing(ast, code, parser, source_maps, version)
    source_file = Parser::Source::Buffer.new('(assert_parses)', source: code)

    begin
      parsed_ast = parser.parse(source_file)
    rescue => exc
      backtrace = exc.backtrace
      Exception.instance_method(:initialize).bind(exc).
        call("(#{version}) #{exc.message}")
      exc.set_backtrace(backtrace)
      raise
    end

    if ast.nil?
      assert_nil parsed_ast, "(#{version}) AST equality"
      return
    end

    assert_equal ast, parsed_ast,
                 "(#{version}) AST equality"

    parse_source_map_descriptions(source_maps) do |range, map_field, ast_path, line|

      astlet = traverse_ast(parsed_ast, ast_path)

      if astlet.nil?
        # This is a testsuite bug.
        raise "No entity with AST path #{ast_path} in #{parsed_ast.inspect}"
      end

      assert astlet.frozen?

      assert astlet.location.respond_to?(map_field),
             "(#{version}) #{astlet.location.inspect}.respond_to?(#{map_field.inspect}) for:\n#{parsed_ast.inspect}"

      found_range = astlet.location.send(map_field)

      assert_source_range(range, found_range, version, line.inspect)
    end

    assert_state_is_final(parser, version)
  end

  # Use like this:
  # ~~~
  # assert_diagnoses(
  #   [:warning, :ambiguous_prefix, { prefix: '*' }],
  #   %q{foo *bar},
  #   %q{    ^ location
  #     |     ~~~ highlights (0)})
  # ~~~
  def assert_diagnoses(diagnostic, code, source_maps='', versions=ALL_VERSIONS)
    with_versions(versions) do |version, parser|
      source_file = Parser::Source::Buffer.new('(assert_diagnoses)', source: code)

      begin
        parser = parser.parse(source_file)
      rescue Parser::SyntaxError
        # do nothing; the diagnostic was reported
      end

      assert_equal 1, @diagnostics.count,
                   "(#{version}) emits a single diagnostic, not\n" \
                   "#{@diagnostics.map(&:render).join("\n")}"

      emitted_diagnostic = @diagnostics.first

      level, reason, arguments = diagnostic
      arguments ||= {}
      message     = Parser::Messages.compile(reason, arguments)

      assert_equal level, emitted_diagnostic.level
      assert_equal reason, emitted_diagnostic.reason
      assert_equal arguments, emitted_diagnostic.arguments
      assert_equal message, emitted_diagnostic.message

      parse_source_map_descriptions(source_maps) do |range, map_field, ast_path, line|

        case map_field
        when 'location'
          assert_source_range range,
                              emitted_diagnostic.location,
                              version, 'location'

        when 'highlights'
          index = ast_path.first.to_i

          assert_source_range range,
                              emitted_diagnostic.highlights[index],
                              version, "#{index}th highlight"

        else
          raise "Unknown diagnostic range #{map_field}"
        end
      end
    end
  end

  # Use like this:
  # ~~~
  # assert_diagnoses_many(
  #   [
  #     [:warning, :ambiguous_literal],
  #     [:error, :unexpected_token, { :token => :tLCURLY }]
  #   ],
  #   %q{m /foo/ {}},
  #   SINCE_2_4)
  # ~~~
  def assert_diagnoses_many(diagnostics, code, versions=ALL_VERSIONS)
    with_versions(versions) do |version, parser|
      source_file = Parser::Source::Buffer.new('(assert_diagnoses_many)', source: code)

      begin
        parser = parser.parse(source_file)
      rescue Parser::SyntaxError
        # do nothing; the diagnostic was reported
      end

      assert_equal diagnostics.count, @diagnostics.count

      diagnostics.zip(@diagnostics) do |expected_diagnostic, actual_diagnostic|
        level, reason, arguments = expected_diagnostic
        arguments ||= {}
        message     = Parser::Messages.compile(reason, arguments)

        assert_equal level, actual_diagnostic.level
        assert_equal reason, actual_diagnostic.reason
        assert_equal arguments, actual_diagnostic.arguments
        assert_equal message, actual_diagnostic.message
      end
    end
  end

  def refute_diagnoses(code, versions=ALL_VERSIONS)
    with_versions(versions) do |version, parser|
      source_file = Parser::Source::Buffer.new('(refute_diagnoses)', source: code)

      begin
        parser = parser.parse(source_file)
      rescue Parser::SyntaxError
        # do nothing; the diagnostic was reported
      end

      assert_empty @diagnostics,
                   "(#{version}) emits no diagnostics, not\n" \
                   "#{@diagnostics.map(&:render).join("\n")}"
    end
  end

  def assert_context(context, code, versions=ALL_VERSIONS)
    with_versions(versions) do |version, parser|
      source_file = Parser::Source::Buffer.new('(assert_context)', source: code)

      parsed_ast = parser.parse(source_file)

      nodes = find_matching_nodes(parsed_ast) { |node| node.type == :send && node.children[1] == :get_context }
      assert_equal 1, nodes.count, "there must exactly 1 `get_context()` call"

      node = nodes.first
      actual_context = Parser::Context::FLAGS.each_with_object([]) { |flag, acc| acc << flag if node.context.public_send(flag) }
      assert_equal context.sort, actual_context.sort, "(#{version}) expect parsing context to match"
    end
  end

  SOURCE_MAP_DESCRIPTION_RE =
      /(?x)
       ^(?# $1 skip)            ^(\s*)
        (?# $2 highlight)        ([~\^]+|\!)
                                 \s+
        (?# $3 source_map_field) ([a-z_]+)
        (?# $5 ast_path)         (\s+\(([a-z_.\/0-9]+)\))?
                                $/

  def parse_source_map_descriptions(descriptions)
    unless block_given?
      return to_enum(:parse_source_map_descriptions, descriptions)
    end

    descriptions.each_line do |line|
      # Remove leading "     |", if it exists.
      line = line.sub(/^\s*\|/, '').rstrip

      next if line.empty?

      if (match = SOURCE_MAP_DESCRIPTION_RE.match(line))
        if match[2] != '!'
          begin_pos        = match[1].length
          end_pos          = begin_pos + match[2].length
          range            = begin_pos...end_pos
        end
        source_map_field = match[3]

        if match[5]
          ast_path = match[5].split('.')
        else
          ast_path = []
        end

        yield range, source_map_field, ast_path, line
      else
        raise "Cannot parse source map description line: #{line.inspect}."
      end
    end
  end

  def traverse_ast(ast, path)
    path.inject(ast) do |astlet, path_component|
      # Split "dstr/2" to :dstr and 1
      type_str, index_str = path_component.split('/')

      type  = type_str.to_sym

      if index_str.nil?
        index = 0
      else
        index = index_str.to_i - 1
      end

      matching_children = \
        astlet.children.select do |child|
          AST::Node === child && child.type == type
        end

      matching_children[index]
    end
  end

  def find_matching_nodes(ast, &block)
    return [] unless ast.is_a?(AST::Node)

    result = []
    result << ast if block.call(ast)
    ast.children.each { |child| result += find_matching_nodes(child, &block) }

    result
  end

  def assert_state_is_final(parser, version)
    lexer = parser.lexer

    assert lexer.cmdarg.empty?, "(#{version}) expected cmdarg to be empty after parsing"
    assert lexer.cond.empty?, "(#{version}) expected cond to be empty after parsing"

    assert lexer.cmdarg_stack.empty?, "(#{version}) expected cmdarg_stack to be empty after parsing"
    assert lexer.cond_stack.empty?, "(#{version}) expected cond_stack to be empty after parsing"

    assert_equal 0, lexer.paren_nest, "(#{version}) expected paren_nest to be 0 after parsing"
    assert lexer.lambda_stack.empty?, "(#{version}) expected lambda_stack to be empty after parsing"

    assert parser.static_env.empty?, "(#{version}) expected static_env to be empty after parsing"
    Parser::Context::FLAGS.each do |ctx_flag|
      refute parser.context.public_send(ctx_flag), "(#{version}) expected context.#{ctx_flag} to be `false` after parsing"
    end
    assert parser.max_numparam_stack.empty?, "(#{version}) expected max_numparam_stack to be empty after parsing"
    assert parser.current_arg_stack.empty?, "(#{version}) expected current_arg_stack to be empty after parsing"
    assert parser.pattern_variables.empty?, "(#{version}) expected pattern_variables to be empty after parsing"
    assert parser.pattern_hash_keys.empty?, "(#{version}) expected pattern_hash_keys to be empty after parsing"
  end
end
