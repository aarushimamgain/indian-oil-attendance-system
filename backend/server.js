const express = require("express");
const cors = require("cors");
const bodyParser = require("body-parser");
require("dotenv").config();
const { createClient } = require("@supabase/supabase-js");

const app = express();
app.use(cors());
app.use(express.json());
app.use(bodyParser.json());

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_KEY
);

// PATCH /api/approval/:id
app.patch("/api/approval/:id", async (req, res) => {
  const { id } = req.params;
  const { decision, approved_by } = req.body; // 'approved' or 'rejected'

  const { error } = await supabase
    .from("approval_requests")
    .update({
      status: decision,
      approved_by,
      approved_at: new Date().toISOString()
    })
    .eq("id", id);

  if (error) return res.status(500).json({ message: "Error" });
  res.status(200).json({ message: "Updated" });
});


// 🔹 LOGIN
app.post("/api/login", async (req, res) => {
  const { emp_no, shift_name } = req.body;
  const { data, error } = await supabase
    .from("shifts")
    .select("emp_no, shiftname")
    .eq("emp_no", emp_no.toString());

  if (!data || data.length === 0) {
    return res.status(404).json({ message: "User not found" });
  }

  const user = data[0];
  if (!user.shiftname || user.shiftname.trim() === "") {
    await supabase
      .from("shifts")
      .update({ shiftname: shift_name.trim() })
      .eq("emp_no", emp_no.toString());
    user.shiftname = shift_name.trim();
  }

  return res.status(200).json({ user });
});

// 🔹 ATTENDANCE (TABLE VIEW)
app.post("/api/calculate", async (req, res) => {
  const { employee_number, startDate, endDate } = req.body;

  try {
    const { data, error } = await supabase
  .from("calendar_view")
  .select("date, shift_name, status")
  .eq("emp_no", employee_number)
  .gte("date", startDate)
  .lte("date", endDate)
  .order("date", { ascending: true }); // ✅ .order should be chained on the same line


    if (error) {
      return res.status(500).json({ message: "Error fetching from calendar_view." });
    }

    return res.status(200).json({ data });
  } catch (err) {
    console.error("Server error:", err);
    return res.status(500).json({ message: "Server error" });
  }
});

// 🔹 MONTHLY ATTENDANCE (CALENDAR VIEW)
app.post("/api/monthly-attendance", async (req, res) => {
  try {
    const { employee_number, year, month } = req.body;


const startDate = `${year}-${String(month).padStart(2, "0")}-01`;

    // ✅ Correct way to get last day of month
   const endObj = new Date(year, parseInt(month) + 1, 1); // 1st of next month
endObj.setDate(endObj.getDate() - 1);                  // last day of current month (e.g. 31st July)
const endDate = endObj.toISOString().split("T")[0];

console.log("Start:", startDate, "End:", endDate);

    const { data, error } = await supabase
      .from("calendar_view")
      .select("date, shift_name, status")
      .eq("emp_no", employee_number)
      .gte("date", startDate)
      .lte("date", endDate);

    if (error) {
      return res.status(500).json({ message: "Error fetching from calendar_view." });
    }

    return res.status(200).json({ data });
  } catch (err) {
    console.error("Server error:", err);
    return res.status(500).json({ message: "Server error" });
  }
});



// (Optional) Keep helper functions if needed elsewhere
function getDateRange(start, end) {
  const dates = [];
  let current = new Date(start);
  const last = new Date(end);
  while (current <= last) {
    dates.push(current.toISOString().split("T")[0]);
    current.setDate(current.getDate() + 1);
  }
  return dates;
}

function getMinutesDifference(start, end) {
  const [sh, sm] = start.split(":").map(Number);
  const [eh, em] = end.split(":").map(Number);
  let diff = (eh * 60 + em) - (sh * 60 + sm);
  if (diff < 0) diff += 24 * 60;
  return diff;
}

function addMinutesToTime(time, minsToAdd) {
  const [h, m] = time.split(":").map(Number);
  const totalMinutes = h * 60 + m + minsToAdd;
  const newH = String(Math.floor((totalMinutes + 1440) % 1440 / 60)).padStart(2, "0");
  const newM = String((totalMinutes % 60 + 60) % 60).padStart(2, "0");
  return `${newH}:${newM}`;
}

const PORT = 5000;
app.listen(PORT, () => {
  console.log(`✅ Server running at http://localhost:${PORT}`);
});










