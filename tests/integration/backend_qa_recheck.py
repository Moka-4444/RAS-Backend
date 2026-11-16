"""Replay the 50 operations in the original RAS QA report against disposable CI."""

import json
import os
from datetime import date
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("Run this test only in the disposable Docker CI stack")
    fixture = dict(
        line.split("=", 1) for line in Path(".env").read_text().splitlines() if "=" in line
    )
    email = fixture["SEED_CEO_EMAIL"]
    if not email.endswith("@example.test"):
        raise SystemExit("A disposable test account is required")

    state = {"date": date.today().isoformat()}
    headers = {"Content-Type": "application/json"}
    results = []

    def step(label, port, path, method="GET", data=None, expected=200, capture=None, unwrap=None):
        try:
            path = path.format_map(state)
            if data is not None:
                data = {key: value.format_map(state) if isinstance(value, str) else value for key, value in data.items()}
                if "items" in data:
                    data["items"] = [
                        {key: value.format_map(state) if isinstance(value, str) else value for key, value in item.items()}
                        for item in data["items"]
                    ]
        except KeyError as error:
            results.append((label, "SKIP", f"missing test fixture {error}"))
            return None
        request = Request(
            f"http://127.0.0.1:{port}/api/v1{path}", method=method, headers=headers,
            data=json.dumps(data).encode() if data is not None else None,
        )
        try:
            with urlopen(request, timeout=15) as response:
                if response.status != expected:
                    results.append((label, "FAIL", f"HTTP {response.status}, expected {expected}"))
                    return None
                body = response.read()
                if capture or label == "login after rotation":
                    body = json.loads(body)
                if capture:
                    state[capture] = (body[unwrap] if unwrap else body)["id"]
        except (HTTPError, URLError, TimeoutError, ValueError, KeyError, TypeError) as error:
            detail = f"HTTP {error.code}" if isinstance(error, HTTPError) else type(error).__name__
            results.append((label, "FAIL", detail))
            return None
        results.append((label, "PASS", f"HTTP {expected}"))
        return body

    # The preceding feature smoke rotates the disposable CEO password.
    login = {"email": email, "password": fixture["SEED_CEO_PASSWORD"] + "A9"}
    session = step("login after rotation", 9001, "/auth/login", "POST", login)
    if session:
        user = session["user"]
        state["actor"] = user["id"]
        headers.update({
            "Authorization": "Bearer " + session["access_token"],
            "X-User-ID": user["id"], "X-User-Role": user["role"],
        })

    for label, port, path in (
        ("read branches", 9002, "/branches"),
        ("read employees", 9003, "/employees"),
        ("read users", 9001, "/users"),
        ("read overtime", 9003, "/overtime"),
        ("read menu/items", 9005, "/menu/items"),
        ("read menu/categories", 9005, "/menu/categories"),
        ("read central-kitchen/supply/requests", 9004, "/supply/requests"),
        ("read transfers", 9008, "/transfers"),
        ("read reports/sales", 9009, "/reports/sales"),
        ("read reports/inventory", 9009, "/reports/inventory"),
        ("read reports/attendance", 9009, "/reports/attendance"),
        ("read reports/approvals", 9009, "/reports/approvals"),
        ("read reports/audit", 9009, "/reports/audit"),
    ):
        step(label, port, path)

    branch = {"type": "branch", "address": "Disposable QA", "official_start_time": "09:00", "late_rate": 0}
    step("create source", 9002, "/branches", "POST", {**branch, "name": "QA Source"}, 201, "source")
    step("create destination", 9002, "/branches", "POST", {**branch, "name": "QA Destination"}, 201, "destination")
    step("update branch", 9002, "/branches/{source}", "PATCH", {"address": "Updated QA"})
    step("read back branch", 9002, "/branches/{source}")
    step("create menu category", 9005, "/menu/categories", "POST", {"name": "QA Category"}, 201, "category")
    item = {"name": "QA Item", "category_id": "{category}", "selling_price": 35}
    step("create menu item", 9005, "/menu/items", "POST", {**item, "sku": "QA-ITEM"}, 201, "item")
    step("update menu item", 9005, "/menu/items/{item}", "PATCH", {**item, "name": "QA Updated Item"})
    step("read back menu item", 9005, "/menu/items/{item}")
    step("save item cost", 9007, "/cost/items", "POST", {"menu_item_id": "{item}", "cost_amount": 12})
    step("read back item cost", 9007, "/cost/items/{item}")
    step("create good", 9004, "/inventory/goods", "POST", {
        "sku": "QA-GOOD", "name": "QA Good", "unit": "kg", "unit_cost": 3,
    }, 201, "good")
    step("read back good", 9004, "/inventory/goods/{good}")

    movement = {"branch_id": "{source}", "good_id": "{good}"}
    step("stock in", 9010, "/inventory/movements", "POST", {**movement, "type": "IN", "quantity": 10}, 201)
    step("stock out", 9010, "/inventory/movements", "POST", {
        **movement, "type": "OUT", "quantity": 1, "reason": "Disposable QA stock issue",
    }, 201)
    stock = "/inventory/items/{good}"
    query = "?branch_id={source}"
    step("stock settings", 9010, stock + "/settings" + query, "PATCH", {"min_stock": 1, "reorder_level": 3})
    step("read back stock item", 9010, stock + query)
    for label, suffix in (
        ("read /stock", ""), ("read /stock/summary", "/summary"),
        ("read /stock/movements", "/movements"),
        ("read /stock/movements/summary", "/movements/summary"), ("read /stock/value", "/value"),
    ):
        step(label, 9010, "/inventory" + suffix + query)

    supply = step("create supply request", 9004, "/supply/requests", "POST", {
        "branch_id": "{destination}", "items": [{"good_id": "{good}", "requested_qty": 2}],
    }, 201, "supply")
    if supply:
        items = supply.get("items", [])
        if items:
            state["supply_line"] = items[0]["id"]
    step("approve supply", 9004, "/supply/requests/{supply}/approve", "PATCH", {
        "items": [{"item_id": "{supply_line}", "approved_qty": 2}],
    })
    step("create transfer", 9008, "/transfers", "POST", {
        "source_branch_id": "{source}", "dest_branch_id": "{destination}",
        "good_id": "{good}", "quantity": 2, "reason": "Disposable QA",
    }, 201)
    step("open shift", 9006, "/sales/shifts/open", "POST", {"branch_id": "{source}", "manager_id": "{actor}"}, 201, "shift")
    step("record sale", 9006, "/sales/", "POST", {
        "shift_id": "{shift}", "channel": "RESTAURANT", "items": [{"menu_item_id": "{item}", "quantity": 1}],
    }, 201)
    step("create discount", 9006, "/sales/discounts", "POST", {
        "shift_id": "{shift}", "amount": 2, "reason": "Disposable QA",
    }, 201, "discount")
    step("cancel discount", 9006, "/sales/discounts/{discount}/cancel", "PATCH", {"reason": "Disposable QA"})
    step("close shift", 9006, "/sales/shifts/{shift}/close", "PATCH", {})
    step("read shift summary", 9006, "/sales/shifts/{shift}/summary")

    step("create employee", 9003, "/employees", "POST", {
        "name": "QA Employee", "phone": "01000000010", "national_id": "29901011234567",
        "branch_id": "{source}", "payment_type": "monthly", "payment_amount": 3000, "hire_date": "{date}",
    }, 201, "employee")
    step("read employee", 9003, "/employees/{employee}")
    step("check in", 9003, "/attendance/check-in", "POST", {"employee_id": "{employee}", "source": "manual"}, 201)
    step("check out", 9003, "/attendance/check-out", "POST", {"employee_id": "{employee}"})
    step("create overtime", 9003, "/overtime", "POST", {
        "employee_id": "{employee}", "work_date": "{date}", "hours": 2, "rate_per_hour": 20, "source": "manual",
    }, 201, "overtime")
    step("approve overtime", 9003, "/overtime/{overtime}/approve", "PATCH", {})

    passed = sum(status == "PASS" for _, status, _ in results)
    lines = ["## Backend QA replay", "", "| Case | Result | Detail |", "| --- | --- | --- |"]
    lines.extend(f"| {label} | {status} | {detail} |" for label, status, detail in results)
    lines.extend(["", f"**{passed}/{len(results)} passed**"])
    report = "\n".join(lines) + "\n"
    print(report, flush=True)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as output:
            output.write(report)
        incomplete = [f"{label} ({detail})" for label, status, detail in results if status != "PASS"]
        print(f"::notice title=Backend QA replay::{passed}/{len(results)} passed", flush=True)
        if incomplete:
            print("::error title=QA cases requiring review::" + ", ".join(incomplete), flush=True)
    if len(results) != 50 or passed != 50:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
