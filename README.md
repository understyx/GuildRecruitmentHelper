# GuildRecruitmentHelper

WotLK (3.3.5) addon for guild recruitment management.

## Features

1. **Channel spam scheduler**
   - Configure message + interval per channel.
   - Supports built-in chat types (Say/Yell) and custom channels you are currently in.
   - Enable/disable each channel config and start/stop scheduler.

2. **Automated applicant whisper form**
   - Applicant whispers `!apply` to begin.
   - Addon asks each configured question in order.
   - Applicant can keep sending messages to extend current answer, then send `!next` to move to next question.
   - Answers are stored per applicant when complete.

3. **Application review UI**
   - View stored applicants.
   - Inspect each question and saved answer in the addon window.

## Commands

- `/grh` - Open/close the main window.
- `/grh start` - Enable spam scheduler.
- `/grh stop` - Disable spam scheduler.
