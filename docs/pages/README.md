# Published page sources

These files are copied onto the `gh-pages` branch by the release workflow, beside
the `index.yaml` and `.tgz` that chart-releaser puts there.

They live here rather than only on `gh-pages` so that the published page is
reviewed in a pull request like everything else, and so a hand edit on the
branch cannot silently become the only copy. The release overwrites whatever is
on the branch, so this directory is the source of truth.

| File | Purpose |
|------|---------|
| `index.html` | The landing page at the Pages URL, carrying the page metadata and structured data |
| `robots.txt` | Crawl policy, and the sitemap pointer |
| `sitemap.xml` | The one indexable URL |

Publishing happens in `publish_chart_index`, after the release gate, for the same
reason the index does: nothing a visitor reads should describe a release that has
not been confirmed.
