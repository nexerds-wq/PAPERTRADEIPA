import time
import unittest
from unittest.mock import patch

import nexer_agent as a


class NexerSecurityTests(unittest.TestCase):
    def test_unknown_tools_are_blocked(self):
        result = a.request_tool("powershell_-DeleteEverything")
        self.assertIn("error", result)

    def test_repair_needs_approval(self):
        with patch.object(a, "invoke") as invoke:
            result = a.request_tool("flush_dns")
            self.assertIn("pending", result)
            invoke.assert_not_called()
            action_id = result["pending"]["id"]
            second = a.approve_tool(action_id)
            invoke.assert_called_once_with("flush_dns")
            self.assertNotIn("pending", second)
            invalid = a.approve_tool(action_id)
            self.assertEqual(invalid.get("error"), "Approval expired")

    def test_expired_approval_is_rejected(self):
        with patch.object(a, "invoke") as invoke:
            with a.pending_lock:
                a.pending["expired-id"] = ("run_sfc", time.monotonic() - 1)
            result = a.approve_tool("expired-id")
            self.assertIn("error", result)
            invoke.assert_not_called()

    def test_invalid_model_rejected_before_network_call(self):
        with patch.object(a, "ollama_call") as call:
            result = a.chat("hi", "", "model; bad_command")
            self.assertIn("Invalid", result["reply"])
            call.assert_not_called()

    def test_invalid_image_rejected_before_network_call(self):
        with patch.object(a, "ollama_call") as call:
            result = a.chat("inspect", "not base64 @$", "qwen3-vl:4b")
            self.assertIn("Invalid image", result["reply"])
            call.assert_not_called()

    def test_no_arbitrary_command_action(self):
        self.assertNotIn("run_shell", a.TOOLS)
        self.assertNotIn("run_cmd", a.TOOLS)
        self.assertNotIn("run_powershell", a.TOOLS)
        for _, risk, _, argv, _ in a.TOOLS.values():
            self.assertIn(risk, ("green", "yellow"))
            self.assertIsInstance(argv, list)
            self.assertGreater(len(argv), 0)


if __name__ == "__main__":
    unittest.main()
