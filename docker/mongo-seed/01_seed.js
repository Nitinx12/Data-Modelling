// mongo-seed/01_seed.js
// Seeded automatically by the mongo:7 entrypoint (files in /docker-entrypoint-initdb.d/*.js
// run against MONGO_INITDB_DATABASE on first boot). This populates the `source` database
// with a trimmed but structurally-faithful slice of every collection consumed by the
// warehouse models + a few empty unconsumed collections for completeness.
//
// Coverage: 5-10 docs per collection is enough to prove the pipeline; keep update_at
// populated so the incremental watermark logic in pg_staging.py is exercised.

/* eslint-disable no-undef */
db = db.getSiblingDB("source");

// --- helpers ---
function oid() { return ObjectId(); }
function now() { return new Date().toISOString(); }

// Clean slate on first boot (harmless on re-run if volume persists — init only runs once)
[
  "cust_master","customer_contach","user_details","addres","cities",
  "campaing_logs","campaing_sku","products","subcategory","channels",
  "orders_2025","orders_2026","order_line_items","inventory",
  "shipments","invoices","payments",
  "dim_orders","exchange_rate","invoice_inlines","region","security","sheet_1","target_revenue"
].forEach(function (c) { db[c].deleteMany({}); });

// --- cities / addres / cust_master / customer_contach / user_details (dim_customers + dim_geo) ---
db.cities.insertMany([
  { _id: oid(), CityName: "Mumbai",     RegionName: "West",  update_at: now() },
  { _id: oid(), CityName: "Pune",       RegionName: "West",  update_at: now() },
  { _id: oid(), CityName: "Bangalore",  RegionName: "South", update_at: now() },
  { _id: oid(), CityName: "Delhi",      RegionName: "North", update_at: now() }
]);

db.addres.insertMany([
  { _id: oid(), AddressID: "ADDR001", Street: "101 MG Road",      CityName: "Mumbai",    update_at: now() },
  { _id: oid(), AddressID: "ADDR002", Street: "22 FC Road",       CityName: "Pune",      update_at: now() },
  { _id: oid(), AddressID: "ADDR003", Street: "5 Residency Road", CityName: "Bangalore", update_at: now() }
]);

db.cust_master.insertMany([
  { _id: oid(), CustomerID: "CUST001", CustomerName: "Acme Corp",    Segment: "Enterprise", AccountManager: "R. Shah",  PaymentTerms: "Net 30", AddressID: "ADDR001", update_at: now() },
  { _id: oid(), CustomerID: "CUST002", CustomerName: "Globex Ltd",   Segment: "SMB",        AccountManager: "P. Rao",   PaymentTerms: "Net 15", AddressID: "ADDR002", update_at: now() },
  { _id: oid(), CustomerID: "CUST003", CustomerName: "Initech",      Segment: "Enterprise", AccountManager: "S. Kumar", PaymentTerms: "Net 45", AddressID: "ADDR003", update_at: now() }
]);

db.customer_contach.insertMany([
  { _id: oid(), CustomerID: "CUST001", ContactName: "A. Patel", Email: "ap@acme.example", IsPrimary: true,  update_at: now() },
  { _id: oid(), CustomerID: "CUST002", ContactName: "B. Singh", Email: "bs@globex.example", IsPrimary: true,  update_at: now() },
  { _id: oid(), CustomerID: "CUST003", ContactName: "C. Nair",  Email: "cn@initech.example", IsPrimary: true,  update_at: now() }
]);

db.user_details.insertMany([
  { _id: oid(), UserID: "CUST001", Phone: "9000000001", CreditLimit: 500000, update_at: now() },
  { _id: oid(), UserID: "CUST002", Phone: "9000000002", CreditLimit: 150000, update_at: now() },
  { _id: oid(), UserID: "CUST003", Phone: "9000000003", CreditLimit: 750000, update_at: now() }
]);

// --- products / subcategory (dim_products) ---
db.subcategory.insertMany([
  { _id: oid(), subcategory: "laptops",   category: "Electronics" },
  { _id: oid(), subcategory: "monitors",  category: "Electronics" },
  { _id: oid(), subcategory: "chairs",    category: "Furniture" }
]);

db.products.insertMany([
  { _id: oid(), ProductCode: "PROD-A001", ProductName: "UltraBook X1",   Brand: "Acme",   SubcategoryName: "Laptops",  PrimarySupplier: "Supplier A", UnitPrice: 85000, update_at: now() },
  { _id: oid(), ProductCode: "PROD-A002", ProductName: "4K Monitor 27\"", Brand: "Acme",   SubcategoryName: "Monitors", PrimarySupplier: "Supplier B", UnitPrice: 32000, update_at: now() },
  { _id: oid(), ProductCode: "PROD-B001", ProductName: "Ergo Chair Pro",  Brand: "Globex", SubcategoryName: "Chairs",   PrimarySupplier: "Supplier C", UnitPrice: 18500, update_at: now() },
  // Intentional name collision to exercise the MIN(product_key) GROUP BY guard in fact_orders
  { _id: oid(), ProductCode: "PROD-C001", ProductName: "Kitchen M006",    Brand: "HomeCo", SubcategoryName: "Chairs",   PrimarySupplier: "Supplier D", UnitPrice: 12000, update_at: now() },
  { _id: oid(), ProductCode: "PROD-C002", ProductName: "Kitchen M006",    Brand: "HomeCo", SubcategoryName: "Chairs",   PrimarySupplier: "Supplier E", UnitPrice: 12000, update_at: now() }
]);

// --- channels (dim_orders_flag) ---
db.channels.insertMany([
  { _id: oid(), ChannelCode: 1, ChannelName: "Online" },
  { _id: oid(), ChannelCode: 2, ChannelName: "Retail" },
  { _id: oid(), ChannelCode: 3, ChannelName: "Partner" }
]);

// --- campaing_logs / campaing_sku (dim_campaign, fact_campaign_spend, fact_less_fact) ---
db.campaing_logs.insertMany([
  { _id: oid(), CampaignName: "Diwali 2025", Channel: "Online",  StartDate: "2025-10-15", EndDate: "2025-11-15", Budget: 500000, Date: "2025-10-20", Impressions: 120000, Clicks: 3400, Spend: 45000, update_at: now() },
  { _id: oid(), CampaignName: "Diwali 2025", Channel: "Online",  StartDate: "2025-10-15", EndDate: "2025-11-15", Budget: 500000, Date: "2025-10-21", Impressions: 130000, Clicks: 3600, Spend: 52000, update_at: now() },
  { _id: oid(), CampaignName: "New Year 2026", Channel: "Retail", StartDate: "2026-01-01", EndDate: "2026-01-15", Budget: 300000, Date: "2026-01-05", Impressions: 90000,  Clicks: 2100, Spend: 31000, update_at: now() }
]);

db.campaing_sku.insertMany([
  { _id: oid(), CampaignName: "Diwali 2025",   PromotedSKUs: "PROD-A001",  PromotedSKU: "UltraBook X1",  update_at: now() },
  { _id: oid(), CampaignName: "Diwali 2025",   PromotedSKUs: "PROD-A002",  PromotedSKU: "4K Monitor 27\"", update_at: now() },
  { _id: oid(), CampaignName: "New Year 2026", PromotedSKUs: "PROD-B001",  PromotedSKU: "Ergo Chair Pro", update_at: now() }
]);

// --- orders + line items (dim_orders_flag, fact_order_process, fact_orders) ---
db.orders_2025.insertMany([
  { _id: oid(), OrderID: "ORD-2025-0001", CustomerName: "Acme Corp",  CustomerCity: "Mumbai", RegionName: "West",  ShipToCity: "Mumbai", BillToCity: "Mumbai", OrderDate: "2025-06-10", OrderChannel: 1, Status: "Shipped",   Priority: "High",   OrderTotal: 117000, OrderNotes: null, GiftMessage: null, SourceFile: "seed", source_sheet: "orders_2025", update_at: now() },
  { _id: oid(), OrderID: "ORD-2025-0002", CustomerName: "Globex Ltd", CustomerCity: "Pune",   RegionName: "West",  ShipToCity: "Pune",   BillToCity: "Pune",   OrderDate: "2025-07-02", OrderChannel: 2, Status: "Delivered", Priority: "Medium", OrderTotal: 50500,  OrderNotes: null, GiftMessage: null, SourceFile: "seed", source_sheet: "orders_2025", update_at: now() },
  { _id: oid(), OrderID: "ORD-2025-0003", CustomerName: "Initech",    CustomerCity: "Bangalore", RegionName: "South", ShipToCity: "Delhi",  BillToCity: "Bangalore", OrderDate: "2025-08-15", OrderChannel: 1, Status: "Ordered", Priority: "Low",  OrderTotal: 12000,  OrderNotes: null, GiftMessage: null, SourceFile: "seed", source_sheet: "orders_2025", update_at: now() }
]);

db.orders_2026.insertMany([
  { _id: oid(), OrderID: "ORD-2026-0001", CustomerName: "Acme Corp", CustomerCity: "Mumbai", RegionName: "West", ShipToCity: "Mumbai", BillToCity: "Delhi", OrderDate: "2026-02-10", OrderChannel: 3, Status: "Ordered", Priority: "High", OrderTotal: 85000, OrderNotes: null, GiftMessage: null, SourceFile: null, source_sheet: "orders_2026", update_at: now() }
]);

db.order_line_items.insertMany([
  { _id: oid(), OrderID: "ORD-2025-0001", LineID: "1", ProductName: "UltraBook X1",    Quantity: 1, UnitPrice: 85000, UnitCost: 62000, DiscountPct: 0,    LineTotal: 85000, update_at: now() },
  { _id: oid(), OrderID: "ORD-2025-0001", LineID: "2", ProductName: "4K Monitor 27\"", Quantity: 1, UnitPrice: 32000, UnitCost: 21000, DiscountPct: 0,    LineTotal: 32000, update_at: now() },
  { _id: oid(), OrderID: "ORD-2025-0002", LineID: "1", ProductName: "Ergo Chair Pro",  Quantity: 2, UnitPrice: 18500, UnitCost: 12000, DiscountPct: 0.05, LineTotal: 35150, update_at: now() },
  { _id: oid(), OrderID: "ORD-2025-0003", LineID: "1", ProductName: "Kitchen M006",    Quantity: 1, UnitPrice: 12000, UnitCost: 8000,  DiscountPct: 0,    LineTotal: 12000, update_at: now() },
  { _id: oid(), OrderID: "ORD-2026-0001", LineID: "1", ProductName: "UltraBook X1",    Quantity: 1, UnitPrice: 85000, UnitCost: 62000, DiscountPct: 0.1,  LineTotal: 76500, update_at: now() }
]);

// --- inventory (fact_inventory) — wide 2025 months ---
db.inventory.insertMany([
  { _id: oid(), ProductName: "UltraBook X1",   "2025-01": 120, "2025-02": 110, "2025-03": 105, "2025-04": 98, "2025-05": 90, "2025-06": 85, "2025-07": 80, "2025-08": 75, "2025-09": 70, "2025-10": 65, "2025-11": 60, "2025-12": 55, update_at: now() },
  { _id: oid(), ProductName: "Ergo Chair Pro", "2025-01": 200, "2025-02": 195, "2025-03": 190, "2025-04": 185,"2025-05": 180,"2025-06": 175,"2025-07": 170,"2025-08": 165,"2025-09": 160,"2025-10": 155,"2025-11": 150,"2025-12": 145, update_at: now() }
]);

// --- shipments / invoices / payments (fact_order_process) ---
db.shipments.insertMany([
  { _id: oid(), OrderID: "ORD-2025-0001", ShipDate: "2025-06-12", DeliveryDate: "2025-06-15", ShipMode: "Express", update_at: now() },
  { _id: oid(), OrderID: "ORD-2025-0002", ShipDate: "2025-07-04", DeliveryDate: "2025-07-07", ShipMode: "Standard", update_at: now() }
]);

db.invoices.insertMany([
  { _id: oid(), OrderID: "ORD-2025-0001", InvoiceID: "INV-0001", InvoiceDate: "2025-06-13", Amount: 117000, update_at: now() },
  { _id: oid(), OrderID: "ORD-2025-0002", InvoiceID: "INV-0002", InvoiceDate: "2025-07-05", Amount: 50500,  update_at: now() }
]);

db.payments.insertMany([
  { _id: oid(), InvoiceID: "INV-0001", PayDate: "2025-06-20", update_at: now() },
  { _id: oid(), InvoiceID: "INV-0002", PayDate: "2025-07-10", update_at: now() }
]);

// --- unconsumed tables (exist but no model reads them — prove extraction still works) ---
db.dim_orders.insertMany([{ _id: oid(), note: "unconsumed", update_at: now() }]);
db.exchange_rate.insertMany([{ _id: oid(), pair: "USD/INR", rate: 83.5, update_at: now() }]);
db.invoice_inlines.insertMany([{ _id: oid(), note: "unconsumed", update_at: now() }]);
db.region.insertMany([{ _id: oid(), RegionName: "West", update_at: now() }]);
db.security.insertMany([{ _id: oid(), note: "unconsumed", update_at: now() }]);
db.sheet_1.insertMany([{ _id: oid(), note: "unconsumed", update_at: now() }]);
db.target_revenue.insertMany([{ _id: oid(), note: "unconsumed", update_at: now() }]);

print("Seed complete: source database populated.");
