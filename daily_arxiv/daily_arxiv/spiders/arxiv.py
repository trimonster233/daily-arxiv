import os
import re

import scrapy


class ArxivSpider(scrapy.Spider):
    name = "arxiv"
    allowed_domains = ["arxiv.org"]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        categories = os.environ.get("CATEGORIES", "cs.CV").split(",")
        self.target_categories = {cat.strip() for cat in categories if cat.strip()}
        self.cross_list_categories = self.target_categories & {"cs.SD", "eess.AS"}
        self.start_urls = [
            f"https://arxiv.org/list/{cat}/new" for cat in sorted(self.target_categories)
        ]
        self.seen_ids = set()

    def parse(self, response):
        # When there are no replacements, the last navigation link can be Cross-lists.
        replacements = response.xpath(
            "//div[@id='dlpage']//li/a[normalize-space(.)='Replacements']/@href"
        ).re_first(r"^#item(\d+)$")
        first_replacement = int(replacements) if replacements is not None else None

        for paper in response.css("dl dt"):
            anchor = paper.css("a[name^='item']::attr(name)").re_first(r"^item(\d+)$")
            if anchor is None or (first_replacement is not None and int(anchor) >= first_replacement):
                continue

            abstract_link = paper.css("a[title='Abstract']::attr(href)").get()
            if not abstract_link:
                continue
            arxiv_id = abstract_link.rsplit("/", 1)[-1]
            if arxiv_id in self.seen_ids:
                continue

            description = paper.xpath("following-sibling::dd[1]")
            if not description:
                continue
            subjects = description.css(".list-subjects").xpath("string(.)").get(default="")
            categories = re.findall(r"\(([\w.-]+)\)", subjects)
            if categories:
                primary, *secondary = categories
                if primary not in self.target_categories and self.cross_list_categories.isdisjoint(secondary):
                    continue
            else:
                self.logger.warning("Could not extract categories for paper %s, including anyway", arxiv_id)

            self.seen_ids.add(arxiv_id)
            self.logger.info("Found paper %s with categories %s", arxiv_id, categories)
            yield {"id": arxiv_id, "categories": categories}
