# Validates every squad role definition's frontmatter with a real YAML parser.
# Run: ruby test/tool/agent_frontmatter_test.rb
require "yaml"
failures = []
Dir[File.join(__dir__, "..", "..", ".claude", "agents", "*.md")].sort.each do |f|
  next if File.basename(f) == "README.md"
  fm = File.read(f)[/\A---\n(.*?)\n---\n/m, 1]
  begin
    y = YAML.safe_load(fm)
    failures << "#{f}: name must match file" unless y["name"] == File.basename(f, ".md")
    failures << "#{f}: description too short" unless y["description"].to_s.length >= 60
  rescue => e
    failures << "#{f}: #{e.message}"
  end
end
if failures.empty?
  puts "agent frontmatter: all valid"
else
  puts failures
  exit 1
end
