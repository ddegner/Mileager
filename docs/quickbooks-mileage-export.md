# QuickBooks Online mileage export

Open a month or Full Year in Mileager, then choose **Export → Export QuickBooks
CSV**. Monthly sidebar context menus and the Mac export commands also offer it.
The filename is `Mileage-2026-09-QuickBooks.csv` for a month or
`Mileage-2026-QuickBooks.csv` for a year. The list's selected vehicle filter applies;
sidebar month exports include all vehicles, matching the existing export policy.

In QuickBooks Online, open **Expenses & Bills → Mileage → Add trip menu →
Import trips**, choose **QuickBooks**, then select the exported file. Select each
period only once and review the imported mileage, vehicle assignment, and
deductions in QuickBooks. The file has no external trip ID for deduplication.
Configure the vehicle in QuickBooks before importing. In the live test, the CSV's
vehicle name did not create a vehicle: QuickBooks assigned the trips to its
existing primary vehicle instead.

## Format research (September 18, 2026)

The signed-in QuickBooks Online mileage screen was inspected in the Codex internal
browser. Its import dropdown offers **MileIQ** and **QuickBooks**. Selecting
QuickBooks instructs users to upload a mileage CSV downloaded from QuickBooks
Online or Self-Employed and explicitly says only business trips are imported.
This is separate from QuickBooks' banking CSV importer.

[Intuit's current mileage guide](https://quickbooks.intuit.com/learn-support/en-us/help-article/track-mileage/automatically-track-mileage-quickbooks-online/L2qPCRGgI_US_en_US)
documents the mileage CSV download. It does not publish a complete import schema.
A [first-hand successful import example in Intuit's community](https://quickbooks.intuit.com/community/other-questions-9/does-quickbooks-allow-a-csv-file-for-my-mileage-to-be-uploaded-i-try-and-get-errors-95862)
provides the nine columns below and uses `Business`, numeric distance, `0` for
deduction, and `Manual` as the logging method. That example dates to May 2022;
it is compatibility evidence, not a versioned Intuit API contract.

[MileIQ's report instructions](https://support.mileiq.com/hc/en-us/articles/203531259-How-to-create-a-Report)
provide a specific QuickBooks CSV option on the Drives report flow.
[Its report reference](https://support.mileiq.com/hc/en-us/articles/208268586-What-does-a-MileIQ-Report-look-like)
describes start/end times and locations, classification, distance/value, and
parking/tolls, sometimes with a summary above the detailed log. Consequently,
an ordinary MileIQ spreadsheet/report is not a stable flat import contract.
Mileager targets the simpler **QuickBooks** choice and does not label the file as
a MileIQ report.

## Column mapping

| Column | Mileager value |
| --- | --- |
| Date | Slice start date, `MM/dd/yyyy`, Gregorian calendar in the report time zone |
| Type | `Business` |
| Trip Purpose | Saved business purpose |
| Vehicle | Saved vehicle name, or empty if unavailable |
| Start Address | Start address, coordinate fallback, or empty |
| End Address | End address, coordinate fallback, or empty |
| Distance | Corrected/reportable distance in miles, two decimals, decimal point, no grouping |
| Deduction | `0`; the tested QuickBooks importer calculated its own potential deduction |
| Logging Method | `Manual` because the records arrive through a file import |

The export is UTF-8 with one header and one row per report allocation, no preamble,
totals, currency symbols, or extra columns. Text uses the existing CSV escaping
and spreadsheet-formula protection. English headers, US date order, and miles
are fixed even if Mileager displays another language, calendar, or distance unit.
This export targets the US mileage importer.

Business classification and a nonblank purpose are required. Personal,
unreviewed, and Not a Drive records are excluded. A period/vehicle with no eligible
trips shows an error rather than offering a header-only import. Merged trips keep
the same month/rate allocations as other exports; distance corrections and
connector mileage remain allocated consistently, without modifying stored trips.
Within each allocation, a merged trip is one row with its start date, first
address, last address, and total reportable miles. Individual legs, intermediate
stops, end dates, times, and the route map are not included in this nine-column
format. Use the canonical CSV or PDF to retain that detail alongside QuickBooks.

This is a mileage transfer. It does not export tolls, parking, notes, or the app's
custom reimbursement rate/currency as a QuickBooks deduction. In the live test,
QuickBooks recalculated potential deductions using its displayed rate even
though the CSV contained zero. Review the resulting deductions in QuickBooks.

## Verification boundary

Automated coverage checks exact CSV text, business eligibility, dates/time zones,
distance corrections, locale independence, escaping, merged year allocations,
period and vehicle selection, protected files, filenames, empty-export errors,
and both period share-sheet entry points. Existing canonical CSV tests remain
unchanged.

September 2026 testing covered the simulator share sheet, the native Mac save
dialog, and imports into QuickBooks Online US. QuickBooks accepted single and
merged trips with their start dates, purposes, endpoint addresses, and total
distances. It calculated potential deductions using its own rate and assigned
trips to the company's configured primary vehicle. Matching against multiple
QuickBooks vehicles remains unverified.
