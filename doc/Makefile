DIAGRAMS_SRC := $(wildcard diagrams/*.puml)
DIAGRAMS_PNG := $(addsuffix .png, $(basename $(DIAGRAMS_SRC)))
DIAGRAMS_SVG := $(addsuffix .svg, $(basename $(DIAGRAMS_SRC)))

# Default target first; build SVGs
svg: $(DIAGRAMS_SVG)
png: $(DIAGRAMS_PNG)

clean:
	rm -f $(DIAGRAMS_PNG) $(DIAGRAMS_SVG)

diagrams/%.png: diagrams/%.puml
	plantuml -tpng $^

diagrams/%.svg: diagrams/%.puml
	plantuml -tsvg $^

.PHONY: png svg clean
