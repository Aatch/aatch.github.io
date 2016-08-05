
module HasExcerpt
    def has_excerpt(input)
        input =~ /<!--\s*more\s*-->/i ? true : false
    end
end

Liquid::Template.register_filter HasExcerpt
