# Real-world reflection decode: an OpenAlex /works record (31 KB, CC0) with
# nested structs, Optional everywhere, a list of structs, a list of strings,
# and an Optional[Dict[String, List[Int]]] (the abstract inverted index).
# Unknown fields (most of the record) must be skipped without annotations.
from emberjson import from_json
from std.sys import is_defined
from std.testing import TestSuite, assert_equal, assert_true


@always_inline
def files_enabled() -> Bool:
    return not is_defined["DISABLE_TEST_FILES"]()


comptime path = "./test/emberjson/reflection/data/openalex_work.json"


@fieldwise_init
struct Author(Copyable, Defaultable, Movable):
    var id: Optional[String]
    var display_name: Optional[String]
    var orcid: Optional[String]

    def __init__(out self):
        self.id = None
        self.display_name = None
        self.orcid = None


@fieldwise_init
struct Authorship(Copyable, Defaultable, Movable):
    var author_position: Optional[String]
    var author: Author
    var raw_author_name: Optional[String]

    def __init__(out self):
        self.author_position = None
        self.author = Author()
        self.raw_author_name = None


@fieldwise_init
struct Ids(Copyable, Defaultable, Movable):
    var openalex: Optional[String]
    var doi: Optional[String]
    var mag: Optional[String]
    var pmid: Optional[String]
    var pmcid: Optional[String]

    def __init__(out self):
        self.openalex = None
        self.doi = None
        self.mag = None
        self.pmid = None
        self.pmcid = None


@fieldwise_init
struct OpenAccess(Copyable, Defaultable, Movable):
    var is_oa: Optional[Bool]
    var oa_status: Optional[String]
    var oa_url: Optional[String]

    def __init__(out self):
        self.is_oa = None
        self.oa_status = None
        self.oa_url = None


@fieldwise_init
struct Location(Copyable, Defaultable, Movable):
    var is_oa: Optional[Bool]
    var landing_page_url: Optional[String]
    var pdf_url: Optional[String]
    var version: Optional[String]
    var license: Optional[String]

    def __init__(out self):
        self.is_oa = None
        self.landing_page_url = None
        self.pdf_url = None
        self.version = None
        self.license = None


@fieldwise_init
struct Work(Copyable, Defaultable, Movable):
    var id: String
    var doi: Optional[String]
    var title: Optional[String]
    var publication_year: Optional[Int]
    var publication_date: Optional[String]
    var type: Optional[String]
    var cited_by_count: Optional[Int]
    var ids: Ids
    var open_access: OpenAccess
    var primary_location: Optional[Location]
    var authorships: List[Authorship]
    var referenced_works: List[String]
    var abstract_inverted_index: Optional[Dict[String, List[Int]]]

    def __init__(out self):
        self.id = ""
        self.doi = None
        self.title = None
        self.publication_year = None
        self.publication_date = None
        self.type = None
        self.cited_by_count = None
        self.ids = Ids()
        self.open_access = OpenAccess()
        self.primary_location = None
        self.authorships = List[Authorship]()
        self.referenced_works = List[String]()
        self.abstract_inverted_index = None


def load() raises -> Work:
    with open(path, "r") as f:
        return from_json[Work](f.read())


def test_scalars_and_nested_structs() raises:
    comptime if files_enabled():
        var w = load()
        assert_equal(w.id, "https://openalex.org/W2741809807")
        assert_equal(w.doi.value(), "https://doi.org/10.7717/peerj.4375")
        assert_equal(w.publication_year.value(), 2018)
        assert_equal(w.cited_by_count.value(), 1252)
        assert_equal(w.type.value(), "article")
        assert_equal(
            w.ids.pmid.value(), "https://pubmed.ncbi.nlm.nih.gov/29456894"
        )
        assert_equal(w.open_access.oa_status.value(), "gold")


def test_json_null_becomes_none() raises:
    comptime if files_enabled():
        var w = load()
        assert_true(w.ids.pmcid is None)


def test_optional_struct_present() raises:
    comptime if files_enabled():
        var w = load()
        assert_true(w.primary_location)
        assert_equal(w.primary_location.value().is_oa.value(), True)


def test_lists_of_structs_and_strings() raises:
    comptime if files_enabled():
        var w = load()
        assert_equal(len(w.referenced_works), 54)
        assert_true(len(w.authorships) > 3)
        assert_equal(w.authorships[0].author_position.value(), "first")
        assert_equal(
            w.authorships[0].author.display_name.value(), "Heather Piwowar"
        )


def test_optional_dict_of_int_lists() raises:
    comptime if files_enabled():
        var w = load()
        assert_true(w.abstract_inverted_index)
        ref idx = w.abstract_inverted_index.value()
        assert_true(len(idx) > 50)
        # first token of the abstract sits at position 0
        var found_zero = False
        for entry in idx.items():
            for pos in entry.value:
                if pos == 0:
                    found_zero = True
        assert_true(found_zero)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
